const std = @import("std");
const manifest = @import("build.zig.zon");
const build_rules = @import("src/build_rules.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // An explicit, project-owned C ABI archive built by scripts/build-loro.sh.
    // The default remains legacy/offline mode; a Loro build is NOT all-Zig.
    const loro_lib = b.option([]const u8, "loro-lib", "Retained Loro C ABI static library (requires Rust)");
    const loro_dylib = b.option([]const u8, "loro-dylib", "Prebuilt macOS retained-Loro dylib (no Rust toolchain needed)");
    if (loro_lib != null and loro_dylib != null) @panic("choose static -Dloro-lib OR dynamic -Dloro-dylib");
    if (loro_dylib) |path| {
        if (target.result.os.tag != .macos) @panic("sideloaded Loro currently supports macOS only");
        if (!std.fs.path.isAbsolute(path)) @panic("-Dloro-dylib requires a trusted absolute artifact path");
        const install_lib = b.addInstallFileWithDir(.{ .cwd_relative = path }, .bin, "libharness_nano_loro.dylib");
        b.getInstallStep().dependOn(&install_lib.step);
    }
    const sync_opts = b.addOptions();
    sync_opts.addOption(bool, "loro_enabled", loro_lib != null or loro_dylib != null);
    sync_opts.addOption(bool, "loro_dynamic", loro_dylib != null);
    const lib_optimize = build_rules.httpZigOptimize(optimize, target.result.os.tag);
    const nanoui = b.dependency("nanoui", .{ .target = target, .optimize = optimize }).module("nanoui");
    // HTTPS with ALPN h2 for what the app asks the network itself (releases,
    // the edge); the engine's own socket is a local WebSocket (src/ws.zig).
    const http_zig = b.dependency("http_zig", .{ .target = target, .optimize = lib_optimize }).module("http_zig");
    const luau = @import("luau_build.zig").module(b, target, lib_optimize);
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
    const base_imports = [_]std.Build.Module.Import{
        .{ .name = "build_info", .module = info_mod },
        .{ .name = "sync_options", .module = sync_opts.createModule() },
        .{ .name = "nanoui", .module = nanoui },
        .{ .name = "http_zig", .module = http_zig },
        .{ .name = "fonts", .module = fonts },
        .{ .name = "icons_svg", .module = icons_svg },
        .{ .name = "file_icons_data", .module = file_icons_data },
        .{ .name = "themes_json", .module = themes_json },
        .{ .name = "ios_themes_json", .module = ios_themes_json },
        .{ .name = "mcp_tools_json", .module = @import("mcp_tools_build.zig").module(b) },
    };
    // ShowVisual's sandbox (src/engine_ports/visual_sandbox.zig) needs Luau,
    // which is C++: Zig's libc++ does not build for iOS, so the phone's
    // in-process engine goes without it (ShowVisual says so there).
    const with_luau = base_imports ++ [_]std.Build.Module.Import{.{ .name = "luau", .module = luau }};
    const imports: []const std.Build.Module.Import = if (target.result.os.tag == .ios) &base_imports else &with_luau;

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
    if (loro_lib != null or loro_dylib != null) run_gate.addArg("--with-loro");
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
        // iOS returns before the desktop artifact loop. The simulator's
        // retained core must be compiled for aarch64-apple-ios-sim, NEVER
        // reused from the macOS dylib or the physical-device target.
        if (loro_lib) |archive| {
            exe.root_module.addObjectFile(.{ .cwd_relative = archive });
            exe.root_module.linkFramework("CoreFoundation", .{});
            exe.root_module.linkSystemLibrary("iconv", .{});
        }
        // The Keychain (session_store.zig), push (ios_push.zig) and
        // MetricKit (ios_crash_reports.zig).
        for ([_][]const u8{ "Security", "UserNotifications", "MetricKit" }) |f| exe.root_module.linkFramework(f, .{});
        iosBundle(b, exe, target, optimize);
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
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run harness-nano tests").dependOn(&run_tests.step);

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
        .{ .name = "sync_options", .module = sync_opts.createModule() },
        .{ .name = "nanoui", .module = nanoui },
        .{ .name = "http_zig", .module = http_zig },
        .{ .name = "mcp_tools_json", .module = @import("mcp_tools_build.zig").module(b) },
        .{ .name = "luau", .module = luau },
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

    // Cache executables used by build run/test do not sit beside installed
    // libraries. Supply the explicit developer path ONLY to these commands,
    // never in the binary/options embedded in a distributable.
    if (loro_dylib) |path| {
        inline for (.{ run, run_tests, run_engine, run_snap }) |runner| {
            runner.setEnvironmentVariable("HARNESS_NANO_LORO_LIBRARY", path);
        }
    }

    // Large UI artifacts must never use Zig's self-hosted backend.
    inline for (.{ exe, tests, snap, profile, vectors, engine_exe }) |artifact| {
        artifact.use_llvm = true;
        linkSqlite(b, artifact.root_module, target);
        if (loro_lib) |archive| {
            artifact.root_module.addObjectFile(.{ .cwd_relative = archive });
            if (target.result.os.tag == .macos) {
                artifact.root_module.linkFramework("Security", .{});
                artifact.root_module.linkFramework("CoreFoundation", .{});
                artifact.root_module.linkSystemLibrary("iconv", .{});
            }
        }
    }
}

/// The iOS app, `zig-out/ios/Harness.app` (and `zig build ipa`'s
/// `zig-out/ios/Harness.ipa`), assembled from nanoui's pieces
/// (`ios.infoPlist`, `ios.executable`, tools/ios/finish.sh) so the
/// Info.plist can carry what `ios.app`'s options don't reach. The rules are
/// src/ios_build_rules.zig's; docs/releases/nano-ios.md explains the options.
fn iosBundle(b: *std.Build, exe: *std.Build.Step.Compile, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const ios = @import("nanoui").ios;
    const rules = @import("src/ios_build_rules.zig");
    const dep = b.dependency("nanoui", .{ .target = target, .optimize = optimize });
    const t = target.result;
    const simulator = t.abi == .simulator;

    const id_option = b.option([]const u8, "ios-bundle-id", "Bundle identifier (default harness.codegraff.ios.nano; harness.codegraff.ios at the cutover)");
    const display_option = b.option([]const u8, "ios-display-name", "Name under the icon (default by bundle id)");
    const version = b.option([]const u8, "ios-version", "CFBundleShortVersionString (default build.zig.zon's version)") orelse manifest.version;
    const build_number = b.option([]const u8, "ios-build-number", "CFBundleVersion, a TestFlight upload's build number (default the version)");
    const identity = b.option([]const u8, "ios-identity", "Signing identity for a device build (from the environment, never committed)");
    const profile = b.option([]const u8, "ios-profile", "Provisioning profile path for a device build");
    const team = b.option([]const u8, "ios-team", "Team id (default the one in testflight.yml)");
    const adhoc = b.option(bool, "ios-adhoc", "Device build signed ad hoc: a compile check that won't install") orelse false;
    const distribution = b.option(bool, "ios-distribution", "App Store / TestFlight signing (production push)") orelse false;
    const widgets = b.option([]const u8, "ios-widgets-appex", "A signed HarnessWidgets.appex from Xcode, embedded in PlugIns/");
    const watch = b.option([]const u8, "ios-watch-app", "A signed HarnessWatch.app from Xcode, embedded in Watch/");

    const ipa_step = b.step("ipa", "Package a signed device build as zig-out/ios/Harness.ipa");
    const bundle_id = rules.bundleId(id_option) catch {
        const fail = b.addFail(b.fmt("-Dios-bundle-id={s} isn't a bundle identifier (reverse DNS: letters, digits, hyphens)", .{id_option.?}));
        b.getInstallStep().dependOn(&fail.step);
        ipa_step.dependOn(&fail.step);
        return;
    };
    const signing = switch (rules.signingPlan(.{
        .simulator = simulator,
        .identity = identity,
        .profile = profile,
        .team = team,
        .adhoc = adhoc,
        .distribution = distribution,
    })) {
        .fail => |why| {
            const fail = b.addFail(b.fmt("ios: {s}", .{why}));
            b.getInstallStep().dependOn(&fail.step);
            ipa_step.dependOn(&fail.step);
            return;
        },
        .sign => |s| s,
    };

    // The Simulator's entitlements go in the program (ios_ship.zig).
    const build_opts = b.addOptions();
    build_opts.addOption([]const u8, "simulated_entitlements", if (simulator) rules.simulatedEntitlementsPlist(b.allocator, signing.team, bundle_id) catch @panic("OOM") else "");
    exe.root_module.addOptions("ios_build", build_opts);

    const opts: ios.Options = .{
        .name = "Harness",
        .id = bundle_id,
        .version = version,
        .multiple_windows = true,
        .info = rules.extraInfo(b.allocator, .{ .bundle_id = bundle_id, .live_activities = widgets != null }) catch @panic("OOM"),
    };
    // What Xcode would stamp: App Store Connect checks a device build's SDK
    // and Xcode by these keys.
    const dt: ?[]const u8 = if (simulator) null else rules.dtKeys(b.allocator, .{
        .sdk_version = b.run(&.{ "xcrun", "--sdk", "iphoneos", "--show-sdk-version" }),
        .sdk_build = b.run(&.{ "xcrun", "--sdk", "iphoneos", "--show-sdk-build-version" }),
        .xcodebuild_version = b.run(&.{ "xcodebuild", "-version" }),
        .os_build = b.run(&.{ "sw_vers", "-buildVersion" }),
    }) catch |err| std.debug.panic("ios: can't read Xcode's version for DTXcode: {t}", .{err});
    const info = rules.patchInfo(b.allocator, ios.infoPlist(b, exe.name, t, opts), .{
        .display_name = rules.displayName(display_option, bundle_id),
        .version = version,
        .build_number = build_number,
        .dt = dt,
    }) catch |err| std.debug.panic("ios: nanoui's Info.plist changed shape ({t}); update src/ios_build_rules.zig patchInfo", .{err});

    const wf = b.addWriteFiles();
    _ = wf.add("Harness.app/Info.plist", info);
    _ = wf.addCopyFile(ios.executable(b, exe), b.fmt("Harness.app/{s}", .{exe.name}));
    // Xcode's own builds, signed with their own profiles: finish.sh keeps a
    // nested signature that verifies and signs the app around it.
    if (widgets) |appex| _ = wf.addCopyDirectory(.{ .cwd_relative = appex }, "Harness.app/PlugIns/HarnessWidgets.appex", .{});
    if (watch) |app| _ = wf.addCopyDirectory(.{ .cwd_relative = app }, "Harness.app/Watch/HarnessWatch.app", .{});
    const made = wf.getDirectory().path(b, "Harness.app");
    const entitlements = b.addWriteFiles().add("Harness.entitlements", rules.entitlementsPlist(b.allocator, signing, bundle_id) catch @panic("OOM"));

    // The asset catalog, compiled as nanoui's `ios.app` does it.
    const min = t.os.version_range.semver.min;
    const actool = b.addSystemCommand(&.{ "xcrun", "actool", "--notices", "--warnings", "--errors", "--output-format", "human-readable-text" });
    actool.addArgs(&.{ "--platform", if (simulator) "iphonesimulator" else "iphoneos", "--minimum-deployment-target", b.fmt("{d}.{d}", .{ min.major, min.minor }) });
    actool.addArgs(&.{ "--target-device", "iphone", "--target-device", "ipad", "--app-icon", "AppIcon", "--output-partial-info-plist" });
    const partial = actool.addOutputFileArg("partial.plist");
    actool.addArg("--compile");
    const compiled = actool.addOutputDirectoryArg("compiled");
    actool.addDirectoryArg(b.addWriteFiles().addCopyDirectory(b.path("assets/ios/Assets.xcassets"), "Assets.xcassets", .{}));

    const finish = std.Build.Step.Run.create(b, "finish Harness.app");
    var finished: ?std.Build.LazyPath = null;
    for (rules.finishArgv(signing)) |arg| switch (arg) {
        .text => |text| finish.addArg(text),
        .finish_script => finish.addFileArg(dep.path("tools/ios/finish.sh")),
        .bundle_in => finish.addDirectoryArg(made),
        .bundle_out => finished = finish.addOutputDirectoryArg("Harness.app"),
        .profile => finish.addFileArg(.{ .cwd_relative = signing.profile.? }),
        .entitlements => finish.addFileArg(entitlements),
        .catalog => finish.addDirectoryArg(compiled),
        .catalog_plist => finish.addFileArg(partial),
        .signed_bundle, .ipa_out => unreachable,
    };
    b.getInstallStep().dependOn(&b.addInstallDirectory(.{
        .source_dir = finished.?,
        .install_dir = .prefix,
        .install_subdir = "ios/Harness.app",
    }).step);

    if (rules.ipaRefusal(signing)) |why| {
        ipa_step.dependOn(&b.addFail(b.fmt("ios: {s}", .{why})).step);
        return;
    }
    const package = std.Build.Step.Run.create(b, "package Harness.ipa");
    var ipa: ?std.Build.LazyPath = null;
    for (rules.ipaArgv()) |arg| switch (arg) {
        .text => |text| package.addArg(text),
        .signed_bundle => package.addDirectoryArg(finished.?),
        .ipa_out => ipa = package.addOutputFileArg("Harness.ipa"),
        else => unreachable,
    };
    ipa_step.dependOn(&b.addInstallFile(ipa.?, "ios/Harness.ipa").step);
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
