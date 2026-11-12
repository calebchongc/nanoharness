//! The iOS app bundle's rules, as build.zig applies them: which bundle id,
//! how the app is signed, what its Info.plist and entitlements say, and the
//! commands that sign, check and package it. Pure, so tests check them
//! without Xcode, a certificate or a profile (src/ios_ship_tests.zig).
//!
//! build.zig imports this file directly, like build_rules.zig: nothing here
//! may import a module the build graph makes.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// The Zig app's own identity until it reaches parity: installs beside the
/// Swift app (apps/ios), on its own App Store Connect record.
pub const nano_bundle_id = "harness.codegraff.ios.nano";
/// The Swift app's identity: `-Dios-bundle-id=harness.codegraff.ios` builds
/// the Zig app as its replacement (docs/releases/nano-ios.md, "Cutover").
pub const swift_bundle_id = "harness.codegraff.ios";
/// The team already public in .github/workflows/testflight.yml.
pub const default_team_id = "WWP9DLJ27P";
/// The asset catalog's color for the launch screen (assets/ios).
pub const launch_color = "LaunchBackground";
/// The scheme a sign-in finished in Safari (a magic link) hands back.
pub const url_scheme = "harness";

/// `option` when given (and well formed), otherwise the Zig app's own id.
pub fn bundleId(option: ?[]const u8) error{InvalidBundleId}![]const u8 {
    const id = option orelse return nano_bundle_id;
    if (!validBundleId(id)) return error.InvalidBundleId;
    return id;
}

/// Reverse DNS as App Store Connect takes it: two or more dot-separated
/// parts of letters, digits and hyphens.
pub fn validBundleId(id: []const u8) bool {
    if (id.len == 0 or id.len > 155) return false;
    var parts = std.mem.splitScalar(u8, id, '.');
    var n: usize = 0;
    while (parts.next()) |part| : (n += 1) {
        if (part.len == 0) return false;
        for (part) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-')) return false;
    }
    return n >= 2;
}

/// The name under the icon: the Swift app's ("Harness") once the Zig app
/// takes its id, otherwise one a person can tell apart on the same phone.
pub fn displayName(option: ?[]const u8, bundle_id: []const u8) []const u8 {
    if (option) |name| if (name.len > 0) return name;
    return if (std.mem.eql(u8, bundle_id, swift_bundle_id)) "Harness" else "Harness Nano";
}

// ── Signing ──────────────────────────────────────────────────────────────

pub const SignInput = struct {
    /// `aarch64-ios-simulator`: always ad hoc, the Simulator asks no more.
    simulator: bool,
    /// As `security find-identity` names it; from the environment or an
    /// argument (`ios.sh --identity`), never from the repository.
    identity: ?[]const u8 = null,
    /// A provisioning profile's path, the same way.
    profile: ?[]const u8 = null,
    team: ?[]const u8 = null,
    /// A device build that is only compiled and signed ad hoc: it won't
    /// install on a phone, but proves the device build links and bundles.
    adhoc: bool = false,
    /// An App Store / TestFlight build (an Apple Distribution identity and
    /// an App Store profile) rather than a development one.
    distribution: bool = false,
};

pub const Kind = enum { simulator, device_adhoc, development, distribution };

pub const Plan = union(enum) {
    sign: Signing,
    /// Why this build can't be made, as the build prints it.
    fail: []const u8,
};

pub const Signing = struct {
    kind: Kind,
    /// "-" signs ad hoc.
    identity: []const u8 = "-",
    profile: ?[]const u8 = null,
    team: []const u8 = default_team_id,
};

pub const missing_identity =
    \\a device build needs a signing identity and a provisioning profile:
    \\  sh scripts/ios.sh device --identity "<identity>" --profile <file.mobileprovision>
    \\  (or HARNESS_IOS_SIGN_IDENTITY and HARNESS_IOS_PROFILE in the environment),
    \\or --adhoc for a compile check that won't install on a phone.
;
pub const missing_profile =
    \\a signed device build needs a provisioning profile too:
    \\  --profile <file.mobileprovision> (or HARNESS_IOS_PROFILE).
;
pub const adhoc_and_identity =
    \\--adhoc signs with no identity: drop it, or drop --identity.
;
pub const distribution_adhoc =
    \\--distribution needs a real signature: an Apple Distribution identity and an App Store profile.
;

/// How a build is signed, or why it can't be. A simulator build is ad hoc
/// whatever it's given; a device build is signed with what it's given, ad
/// hoc only when asked for, and never silently unsigned.
pub fn signingPlan(in: SignInput) Plan {
    const team = if (in.team) |t| (if (t.len > 0) t else default_team_id) else default_team_id;
    if (in.simulator) return .{ .sign = .{ .kind = .simulator, .team = team } };
    const identity: ?[]const u8 = if (in.identity) |i| (if (i.len > 0) i else null) else null;
    const profile: ?[]const u8 = if (in.profile) |p| (if (p.len > 0) p else null) else null;
    if (in.adhoc) {
        if (identity != null) return .{ .fail = adhoc_and_identity };
        if (in.distribution) return .{ .fail = distribution_adhoc };
        return .{ .sign = .{ .kind = .device_adhoc, .team = team } };
    }
    const id = identity orelse return .{ .fail = missing_identity };
    const prof = profile orelse return .{ .fail = missing_profile };
    return .{ .sign = .{
        .kind = if (in.distribution) .distribution else .development,
        .identity = id,
        .profile = prof,
        .team = team,
    } };
}

/// The APNs environment a build's tokens belong to, as its entitlement and
/// the edge (`environment` in the push registration) name it.
pub fn apsEnvironment(kind: Kind) []const u8 {
    return switch (kind) {
        .distribution => "production",
        .simulator, .device_adhoc, .development => "development",
    };
}

/// The entitlements signed into the app. The Swift app's are push only
/// (apps/ios/Harness.entitlements); a signature made outside Xcode also
/// carries what Xcode adds itself. No `keychain-access-groups`: like the
/// Swift app, the Keychain uses the default group, the application
/// identifier, so the cutover build reads the Swift app's items.
pub fn entitlementsPlist(gpa: Allocator, s: Signing, bundle_id: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\
    );
    try w.print("  <key>aps-environment</key><string>{s}</string>\n", .{apsEnvironment(s.kind)});
    switch (s.kind) {
        .simulator, .device_adhoc => {},
        .development, .distribution => {
            try w.print("  <key>application-identifier</key><string>{s}.{s}</string>\n", .{ s.team, bundle_id });
            try w.print("  <key>com.apple.developer.team-identifier</key><string>{s}</string>\n", .{s.team});
            try w.print("  <key>get-task-allow</key><{s}/>\n", .{if (s.kind == .development) "true" else "false"});
            if (s.kind == .distribution) try w.writeAll("  <key>beta-reports-active</key><true/>\n");
        },
    }
    try w.writeAll("</dict>\n</plist>\n");
    return out.toOwnedSlice();
}

/// One argument of a command build.zig runs: text, or a path only the
/// build graph knows (build.zig turns each into addArg, addFileArg, ...).
pub const Arg = union(enum) {
    text: []const u8,
    /// nanoui's tools/ios/finish.sh, from the pinned package.
    finish_script,
    /// The assembled, unsigned `Harness.app`.
    bundle_in,
    /// Where the finished bundle goes.
    bundle_out,
    /// The provisioning profile given (`-Dios-profile`).
    profile,
    entitlements,
    /// actool's compiled catalog and its partial Info.plist.
    catalog,
    catalog_plist,
    /// The finished, signed bundle (`zig build ipa`'s input).
    signed_bundle,
    ipa_out,
};

/// The Simulator's entitlements, as Xcode gives them: not in the signature
/// (see `signsEntitlements`) but in the program's `__TEXT,__entitlements`
/// section, which the Simulator reads instead. Without an application
/// identifier the Simulator's Keychain refuses every SecItem call.
pub fn simulatedEntitlementsPlist(gpa: Allocator, team: []const u8, bundle_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\  <key>application-identifier</key><string>{s}.{s}</string>
        \\  <key>keychain-access-groups</key><array><string>{s}.{s}</string></array>
        \\  <key>aps-environment</key><string>development</string>
        \\</dict>
        \\</plist>
        \\
    , .{ team, bundle_id, team, bundle_id });
}

/// Whether the signature carries the entitlements. Not the Simulator's: its
/// app runs as a Mac process, and the Mac refuses to start one whose ad hoc
/// signature claims a restricted entitlement such as `aps-environment`
/// (launchd: "Launchd job spawn failed", POSIX 163). `simctl push` needs no
/// entitlement.
pub fn signsEntitlements(kind: Kind) bool {
    return kind != .simulator;
}

/// The command that finishes the bundle: nanoui's tools/ios/finish.sh
/// (`finish.sh IN OUT IDENTITY PROFILE ENTITLEMENTS COMPILED PARTIAL`),
/// which merges the compiled catalog, embeds the profile, signs from the
/// inside out with `codesign --force --sign IDENTITY --timestamp=none
/// --entitlements ENTITLEMENTS`, and checks it with `codesign --verify
/// --strict`. IDENTITY "-" is ad hoc; PROFILE "" is none.
pub fn finishArgv(s: Signing) [9]Arg {
    return .{
        .{ .text = "sh" },
        .finish_script,
        .bundle_in,
        .bundle_out,
        .{ .text = s.identity },
        if (s.profile != null) .profile else .{ .text = "" },
        if (signsEntitlements(s.kind)) .entitlements else .{ .text = "" },
        .catalog,
        .catalog_plist,
    };
}

/// What `zig build ipa` runs: the signed app in `Payload/`, zipped the way
/// Xcode's export does (`ditto` keeps the bundle's symlinks and modes).
pub const ipa_script =
    \\set -eu
    \\app="$1"
    \\out="$2"
    \\tmp="$(mktemp -d)"
    \\trap 'rm -rf "$tmp"' EXIT
    \\mkdir "$tmp/Payload"
    \\cp -R "$app" "$tmp/Payload/Harness.app"
    \\codesign --verify --strict --deep "$tmp/Payload/Harness.app"
    \\rm -f "$out"
    \\ditto -c -k --norsrc --noextattr --keepParent "$tmp/Payload" "$out"
;

pub fn ipaArgv() [6]Arg {
    return .{ .{ .text = "sh" }, .{ .text = "-c" }, .{ .text = ipa_script }, .{ .text = "ipa" }, .signed_bundle, .ipa_out };
}

/// An `.ipa` is only worth making from a real signature: an ad hoc one
/// installs nowhere and App Store Connect refuses it.
pub fn ipaRefusal(s: Signing) ?[]const u8 {
    return switch (s.kind) {
        .simulator => "an .ipa is for a device: sh scripts/ios.sh ipa builds -Dtarget=aarch64-ios",
        .device_adhoc => "an .ipa needs a signed device build: --identity and --profile, not --adhoc",
        .development, .distribution => null,
    };
}

// ── Info.plist ───────────────────────────────────────────────────────────

pub const usage_camera = "Harness uses the camera when you take a photo to attach to a message.";
pub const usage_photos_add = "Harness saves images from your chats to your photo library when you ask it to.";
pub const usage_photos = "Harness opens your photo library when you choose a picture to attach to a message.";
pub const usage_microphone = "Harness uses the microphone when you dictate a message.";
pub const usage_speech = "Harness writes out what you dictate, on this iPhone or your Apple Watch, so it can send it to a chat as text.";

pub const InfoInput = struct {
    bundle_id: []const u8,
    /// Set when the Swift extensions (widgets with Live Activities) are
    /// embedded; nanoui draws none of its own.
    live_activities: bool = false,
};

/// What the bundle's Info.plist adds to nanoui's (`ios.app`'s `.info`):
/// export compliance, the sign-in's URL scheme, the privacy prompts'
/// reasons, local networking for the in-process engine. Keys nanoui writes
/// itself (orientations, device families, launch screen) aren't repeated.
/// No background modes and no associated domains: the Swift app has none.
pub fn extraInfo(gpa: Allocator, in: InfoInput) ![]u8 {
    return std.fmt.allocPrint(gpa,
        \\  <key>ITSAppUsesNonExemptEncryption</key><false/>
        \\  <key>CFBundleURLTypes</key>
        \\  <array><dict>
        \\    <key>CFBundleURLName</key><string>{s}.auth</string>
        \\    <key>CFBundleURLSchemes</key><array><string>{s}</string></array>
        \\  </dict></array>
        \\  <key>UIRequiredDeviceCapabilities</key><array><string>arm64</string></array>
        \\  <key>NSCameraUsageDescription</key><string>{s}</string>
        \\  <key>NSPhotoLibraryAddUsageDescription</key><string>{s}</string>
        \\  <key>NSPhotoLibraryUsageDescription</key><string>{s}</string>
        \\  <key>NSMicrophoneUsageDescription</key><string>{s}</string>
        \\  <key>NSSpeechRecognitionUsageDescription</key><string>{s}</string>
        \\  <key>NSAppTransportSecurity</key>
        \\  <dict><key>NSAllowsLocalNetworking</key><true/></dict>
        \\{s}
    , .{
        in.bundle_id,
        url_scheme,
        usage_camera,
        usage_photos_add,
        usage_photos,
        usage_microphone,
        usage_speech,
        if (in.live_activities) "  <key>NSSupportsLiveActivities</key><true/>" else "",
    });
}

pub const Patch = struct {
    display_name: []const u8,
    /// CFBundleVersion: a TestFlight upload's build number. Null keeps the
    /// marketing version nanoui writes there.
    build_number: ?[]const u8 = null,
    version: []const u8,
    /// The toolchain keys App Store Connect checks (a device build's).
    dt: ?[]const u8 = null,
};

/// nanoui's Info.plist (`ios.infoPlist`) with what its options don't reach:
/// the display name apart from the bundle's name, a build number apart
/// from the version, the launch screen's color, and the toolchain keys.
/// Each replaced line must be there: a nanoui that writes them differently
/// fails the build here instead of shipping a plist without them.
pub fn patchInfo(gpa: Allocator, base: []const u8, p: Patch) ![]u8 {
    var text = try gpa.dupe(u8, base);
    errdefer gpa.free(text);
    text = try replaceOnce(gpa, text, "  <key>UILaunchScreen</key><dict/>\n", "  <key>UILaunchScreen</key><dict><key>UIColorName</key><string>" ++ launch_color ++ "</string></dict>\n");
    const name_line = try findKeyLine(text, "CFBundleDisplayName");
    const new_name = try std.fmt.allocPrint(gpa, "  <key>CFBundleDisplayName</key><string>{s}</string>\n", .{p.display_name});
    defer gpa.free(new_name);
    text = try replaceOnce(gpa, text, name_line, new_name);
    if (p.build_number) |n| {
        const old = try std.fmt.allocPrint(gpa, "  <key>CFBundleVersion</key><string>{s}</string>\n", .{p.version});
        defer gpa.free(old);
        const new = try std.fmt.allocPrint(gpa, "  <key>CFBundleVersion</key><string>{s}</string>\n", .{n});
        defer gpa.free(new);
        text = try replaceOnce(gpa, text, old, new);
    }
    if (p.dt) |dt| {
        const tail = try std.mem.concat(gpa, u8, &.{ dt, "</dict>\n</plist>" });
        defer gpa.free(tail);
        text = try replaceOnce(gpa, text, "</dict>\n</plist>", tail);
    }
    return text;
}

fn findKeyLine(text: []const u8, key: []const u8) error{PatchTargetMissing}![]const u8 {
    var buf: [96]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "  <key>{s}</key>", .{key}) catch return error.PatchTargetMissing;
    const start = std.mem.indexOf(u8, text, needle) orelse return error.PatchTargetMissing;
    const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse return error.PatchTargetMissing;
    return text[start .. end + 1];
}

/// `text` with `old` (there exactly once) replaced; frees `text`.
fn replaceOnce(gpa: Allocator, text: []u8, old: []const u8, new: []const u8) ![]u8 {
    const at = std.mem.indexOf(u8, text, old) orelse return error.PatchTargetMissing;
    if (std.mem.indexOfPos(u8, text, at + old.len, old) != null) return error.PatchTargetAmbiguous;
    const out = try std.mem.concat(gpa, u8, &.{ text[0..at], new, text[at + old.len ..] });
    gpa.free(text);
    return out;
}

pub const Toolchain = struct {
    /// `xcrun --sdk iphoneos --show-sdk-version`, e.g. "27.1".
    sdk_version: []const u8,
    /// `xcrun --sdk iphoneos --show-sdk-build-version`, e.g. "23B5050a".
    sdk_build: []const u8,
    /// `xcodebuild -version`: "Xcode 27.1\nBuild version 27B5050a\n".
    xcodebuild_version: []const u8,
    /// `sw_vers -buildVersion`.
    os_build: []const u8,
};

/// Xcode's version as Info.plist's DTXcode spells it: "27.1" is "2710",
/// "16.4.1" is "1641".
pub fn dtXcode(version: []const u8, out: *[4]u8) ?[]const u8 {
    var parts = std.mem.splitScalar(u8, version, '.');
    const major = std.fmt.parseInt(u8, parts.next() orelse return null, 10) catch return null;
    const minor = std.fmt.parseInt(u8, parts.next() orelse "0", 10) catch return null;
    const patch = std.fmt.parseInt(u8, parts.next() orelse "0", 10) catch return null;
    if (major > 99 or minor > 9 or patch > 9) return null;
    return std.fmt.bufPrint(out, "{d:0>2}{d}{d}", .{ major, minor, patch }) catch null;
}

/// The DT* keys Xcode writes into every app it builds; App Store Connect
/// reads them to check the SDK and Xcode an upload was built with, and
/// refuses an upload without them.
pub fn dtKeys(gpa: Allocator, t: Toolchain) ![]u8 {
    var lines = std.mem.splitScalar(u8, t.xcodebuild_version, '\n');
    const first = std.mem.trim(u8, lines.next() orelse "", " \r");
    const second = std.mem.trim(u8, lines.next() orelse "", " \r");
    if (!std.mem.startsWith(u8, first, "Xcode ")) return error.UnreadableXcodeVersion;
    if (!std.mem.startsWith(u8, second, "Build version ")) return error.UnreadableXcodeVersion;
    var xb: [4]u8 = undefined;
    const xcode = dtXcode(first["Xcode ".len..], &xb) orelse return error.UnreadableXcodeVersion;
    const sdk_version = std.mem.trim(u8, t.sdk_version, " \r\n");
    const sdk_build = std.mem.trim(u8, t.sdk_build, " \r\n");
    return std.fmt.allocPrint(gpa,
        \\  <key>DTPlatformName</key><string>iphoneos</string>
        \\  <key>DTPlatformVersion</key><string>{s}</string>
        \\  <key>DTPlatformBuild</key><string>{s}</string>
        \\  <key>DTSDKName</key><string>iphoneos{s}</string>
        \\  <key>DTSDKBuild</key><string>{s}</string>
        \\  <key>DTXcode</key><string>{s}</string>
        \\  <key>DTXcodeBuild</key><string>{s}</string>
        \\  <key>DTCompiler</key><string>com.apple.compilers.llvm.clang.1_0</string>
        \\  <key>BuildMachineOSBuild</key><string>{s}</string>
        \\
    , .{ sdk_version, sdk_build, sdk_version, sdk_build, xcode, second["Build version ".len..], std.mem.trim(u8, t.os_build, " \r\n") });
}

const testing = std.testing;

test "the bundle id defaults to the Zig app's own and refuses a malformed one" {
    try testing.expectEqualStrings("harness.codegraff.ios.nano", try bundleId(null));
    try testing.expectEqualStrings(swift_bundle_id, try bundleId("harness.codegraff.ios"));
    try testing.expectError(error.InvalidBundleId, bundleId("harness"));
    try testing.expectError(error.InvalidBundleId, bundleId("harness..ios"));
    try testing.expectError(error.InvalidBundleId, bundleId("harness.codegraff ios"));
    try testing.expectError(error.InvalidBundleId, bundleId(""));
    // Side by side: the default never collides with the Swift app.
    try testing.expect(!std.mem.eql(u8, try bundleId(null), swift_bundle_id));
}

test "the display name follows the bundle id unless given" {
    try testing.expectEqualStrings("Harness Nano", displayName(null, nano_bundle_id));
    try testing.expectEqualStrings("Harness", displayName(null, swift_bundle_id));
    try testing.expectEqualStrings("Harness Beta", displayName("Harness Beta", nano_bundle_id));
    try testing.expectEqualStrings("Harness Nano", displayName("", nano_bundle_id));
}

test "a simulator build is ad hoc whatever it's given" {
    const plan = signingPlan(.{ .simulator = true, .identity = "Apple Development: Synthetic (ABCDE12345)", .profile = "/tmp/x.mobileprovision" });
    try testing.expectEqual(Kind.simulator, plan.sign.kind);
    try testing.expectEqualStrings("-", plan.sign.identity);
    try testing.expectEqual(@as(?[]const u8, null), plan.sign.profile);
}

test "a device build with no identity fails with what to pass" {
    const plan = signingPlan(.{ .simulator = false });
    try testing.expectEqualStrings(missing_identity, plan.fail);
    try testing.expect(std.mem.indexOf(u8, plan.fail, "HARNESS_IOS_SIGN_IDENTITY") != null);
    try testing.expect(std.mem.indexOf(u8, plan.fail, "--adhoc") != null);
    // An empty variable is no identity either.
    try testing.expectEqualStrings(missing_identity, signingPlan(.{ .simulator = false, .identity = "" }).fail);
    try testing.expectEqualStrings(missing_profile, signingPlan(.{ .simulator = false, .identity = "Apple Development: Synthetic (ABCDE12345)" }).fail);
}

test "device signing: ad hoc only when asked, development or distribution otherwise" {
    const adhoc = signingPlan(.{ .simulator = false, .adhoc = true });
    try testing.expectEqual(Kind.device_adhoc, adhoc.sign.kind);
    try testing.expectEqualStrings("-", adhoc.sign.identity);
    try testing.expectEqualStrings(adhoc_and_identity, signingPlan(.{ .simulator = false, .adhoc = true, .identity = "X" }).fail);
    try testing.expectEqualStrings(distribution_adhoc, signingPlan(.{ .simulator = false, .adhoc = true, .distribution = true }).fail);

    const dev = signingPlan(.{ .simulator = false, .identity = "Apple Development: Synthetic (ABCDE12345)", .profile = "/tmp/dev.mobileprovision" });
    try testing.expectEqual(Kind.development, dev.sign.kind);
    try testing.expectEqualStrings(default_team_id, dev.sign.team);
    const dist = signingPlan(.{ .simulator = false, .identity = "Apple Distribution: Synthetic (ABCDE12345)", .profile = "/tmp/store.mobileprovision", .team = "ABCDE12345", .distribution = true });
    try testing.expectEqual(Kind.distribution, dist.sign.kind);
    try testing.expectEqualStrings("ABCDE12345", dist.sign.team);
    try testing.expectEqualStrings("/tmp/store.mobileprovision", dist.sign.profile.?);
}

test "the finishing argv signs with the identity and embeds the profile only when there is one" {
    const signed = finishArgv(.{ .kind = .distribution, .identity = "Apple Distribution: Synthetic (ABCDE12345)", .profile = "/tmp/p" });
    try testing.expectEqualStrings("sh", signed[0].text);
    try testing.expectEqual(Arg.finish_script, signed[1]);
    try testing.expectEqual(Arg.bundle_in, signed[2]);
    try testing.expectEqual(Arg.bundle_out, signed[3]);
    try testing.expectEqualStrings("Apple Distribution: Synthetic (ABCDE12345)", signed[4].text);
    try testing.expectEqual(Arg.profile, signed[5]);
    try testing.expectEqual(Arg.entitlements, signed[6]);
    try testing.expectEqual(Arg.catalog, signed[7]);
    try testing.expectEqual(Arg.catalog_plist, signed[8]);

    const sim = finishArgv(signingPlan(.{ .simulator = true }).sign);
    try testing.expectEqualStrings("-", sim[4].text);
    try testing.expectEqualStrings("", sim[5].text);
    // The Simulator's ad hoc signature carries no entitlements: it wouldn't start.
    try testing.expectEqualStrings("", sim[6].text);
    const check = finishArgv(signingPlan(.{ .simulator = false, .adhoc = true }).sign);
    try testing.expectEqual(Arg.entitlements, check[6]);
}

test "an ipa only comes from a real signature, zipped as Payload/Harness.app" {
    try testing.expect(ipaRefusal(.{ .kind = .simulator }) != null);
    try testing.expect(ipaRefusal(.{ .kind = .device_adhoc }) != null);
    try testing.expectEqual(@as(?[]const u8, null), ipaRefusal(.{ .kind = .development, .identity = "X", .profile = "/p" }));
    try testing.expectEqual(@as(?[]const u8, null), ipaRefusal(.{ .kind = .distribution, .identity = "X", .profile = "/p" }));
    const argv = ipaArgv();
    try testing.expectEqualStrings("sh", argv[0].text);
    try testing.expectEqualStrings("-c", argv[1].text);
    try testing.expect(std.mem.indexOf(u8, argv[2].text, "Payload/Harness.app") != null);
    try testing.expect(std.mem.indexOf(u8, argv[2].text, "codesign --verify --strict") != null);
    try testing.expect(std.mem.indexOf(u8, argv[2].text, "ditto -c -k --norsrc --noextattr --keepParent") != null);
    try testing.expectEqual(Arg.signed_bundle, argv[4]);
    try testing.expectEqual(Arg.ipa_out, argv[5]);
}

test "entitlements: push always, production only for distribution, no extra keychain group" {
    const gpa = testing.allocator;
    const sim = try entitlementsPlist(gpa, .{ .kind = .simulator }, nano_bundle_id);
    defer gpa.free(sim);
    try testing.expect(std.mem.indexOf(u8, sim, "<key>aps-environment</key><string>development</string>") != null);
    try testing.expect(std.mem.indexOf(u8, sim, "application-identifier") == null);

    const dev = try entitlementsPlist(gpa, .{ .kind = .development, .identity = "X", .profile = "/p", .team = "ABCDE12345" }, nano_bundle_id);
    defer gpa.free(dev);
    try testing.expect(std.mem.indexOf(u8, dev, "<key>application-identifier</key><string>ABCDE12345.harness.codegraff.ios.nano</string>") != null);
    try testing.expect(std.mem.indexOf(u8, dev, "<key>get-task-allow</key><true/>") != null);
    try testing.expect(std.mem.indexOf(u8, dev, "beta-reports-active") == null);

    const dist = try entitlementsPlist(gpa, .{ .kind = .distribution, .identity = "X", .profile = "/p" }, swift_bundle_id);
    defer gpa.free(dist);
    try testing.expect(std.mem.indexOf(u8, dist, "<key>aps-environment</key><string>production</string>") != null);
    try testing.expect(std.mem.indexOf(u8, dist, "<key>application-identifier</key><string>WWP9DLJ27P.harness.codegraff.ios</string>") != null);
    try testing.expect(std.mem.indexOf(u8, dist, "<key>get-task-allow</key><false/>") != null);
    try testing.expect(std.mem.indexOf(u8, dist, "<key>beta-reports-active</key><true/>") != null);
    // The Swift app declares no Keychain sharing: the default group it is.
    for ([_][]const u8{ sim, dev, dist }) |text| try testing.expect(std.mem.indexOf(u8, text, "keychain-access-groups") == null);
}

test "the Simulator's entitlements name the app, for its Keychain" {
    const text = try simulatedEntitlementsPlist(testing.allocator, "ABCDE12345", nano_bundle_id);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "<key>application-identifier</key><string>ABCDE12345.harness.codegraff.ios.nano</string>") != null);
    try testing.expect(std.mem.indexOf(u8, text, "<array><string>ABCDE12345.harness.codegraff.ios.nano</string></array>") != null);
}

test "Info.plist extras: export compliance, the sign-in scheme, every privacy reason, nothing nanoui writes" {
    const gpa = testing.allocator;
    const text = try extraInfo(gpa, .{ .bundle_id = nano_bundle_id });
    defer gpa.free(text);
    for ([_][]const u8{
        "<key>ITSAppUsesNonExemptEncryption</key><false/>",
        "<string>harness.codegraff.ios.nano.auth</string>",
        "<array><string>harness</string></array>",
        "<key>NSCameraUsageDescription</key>",
        "<key>NSPhotoLibraryAddUsageDescription</key>",
        "<key>NSPhotoLibraryUsageDescription</key>",
        "<key>NSMicrophoneUsageDescription</key>",
        "<key>NSSpeechRecognitionUsageDescription</key>",
        "<key>NSAllowsLocalNetworking</key><true/>",
        "<string>arm64</string>",
    }) |want| try testing.expect(std.mem.indexOf(u8, text, want) != null);
    for ([_][]const u8{ "UILaunchScreen", "UISupportedInterfaceOrientations", "UIDeviceFamily", "CFBundleDisplayName", "UIBackgroundModes", "NSSupportsLiveActivities" }) |never|
        try testing.expect(std.mem.indexOf(u8, text, never) == null);
    const with_widgets = try extraInfo(gpa, .{ .bundle_id = swift_bundle_id, .live_activities = true });
    defer gpa.free(with_widgets);
    try testing.expect(std.mem.indexOf(u8, with_widgets, "<key>NSSupportsLiveActivities</key><true/>") != null);
}

/// The lines of nanoui's `ios.infoPlist` that patchInfo replaces, as the
/// pinned nanoui writes them.
const synthetic_base =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<plist version="1.0">
    \\<dict>
    \\  <key>CFBundleName</key><string>Harness</string>
    \\  <key>CFBundleDisplayName</key><string>Harness</string>
    \\  <key>CFBundleShortVersionString</key><string>0.2.186</string>
    \\  <key>CFBundleVersion</key><string>0.2.186</string>
    \\  <key>UILaunchScreen</key><dict/>
    \\</dict>
    \\</plist>
    \\
;

test "patchInfo sets the display name, build number, launch color and toolchain keys" {
    const gpa = testing.allocator;
    const out = try patchInfo(gpa, synthetic_base, .{ .display_name = "Harness Nano", .version = "0.2.186", .build_number = "42", .dt = "  <key>DTXcode</key><string>2710</string>\n" });
    defer gpa.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "<key>CFBundleDisplayName</key><string>Harness Nano</string>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<key>CFBundleName</key><string>Harness</string>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<key>CFBundleVersion</key><string>42</string>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<key>CFBundleShortVersionString</key><string>0.2.186</string>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<key>UILaunchScreen</key><dict><key>UIColorName</key><string>LaunchBackground</string></dict>") != null);
    try testing.expect(std.mem.endsWith(u8, out, "  <key>DTXcode</key><string>2710</string>\n</dict>\n</plist>\n"));

    const plain = try patchInfo(gpa, synthetic_base, .{ .display_name = "Harness", .version = "0.2.186" });
    defer gpa.free(plain);
    try testing.expect(std.mem.indexOf(u8, plain, "<key>CFBundleVersion</key><string>0.2.186</string>") != null);
    try testing.expect(std.mem.indexOf(u8, plain, "DTXcode") == null);
}

test "patchInfo fails loudly when nanoui's plist changes shape" {
    const gpa = testing.allocator;
    try testing.expectError(error.PatchTargetMissing, patchInfo(gpa, "<plist><dict></dict></plist>", .{ .display_name = "H", .version = "1" }));
    try testing.expectError(error.PatchTargetMissing, patchInfo(gpa, synthetic_base, .{ .display_name = "H", .version = "9.9.9", .build_number = "3" }));
}

test "the toolchain keys come from xcodebuild's own words" {
    var buf: [4]u8 = undefined;
    try testing.expectEqualStrings("2710", dtXcode("27.1", &buf).?);
    try testing.expectEqualStrings("1641", dtXcode("16.4.1", &buf).?);
    try testing.expectEqualStrings("2600", dtXcode("26", &buf).?);
    try testing.expectEqual(@as(?[]const u8, null), dtXcode("beta", &buf));

    const gpa = testing.allocator;
    const keys = try dtKeys(gpa, .{ .sdk_version = "27.1\n", .sdk_build = "23B5050a\n", .xcodebuild_version = "Xcode 27.1\nBuild version 27B5050a\n", .os_build = "26A100\n" });
    defer gpa.free(keys);
    for ([_][]const u8{
        "<key>DTPlatformName</key><string>iphoneos</string>",
        "<key>DTSDKName</key><string>iphoneos27.1</string>",
        "<key>DTSDKBuild</key><string>23B5050a</string>",
        "<key>DTXcode</key><string>2710</string>",
        "<key>DTXcodeBuild</key><string>27B5050a</string>",
        "<key>BuildMachineOSBuild</key><string>26A100</string>",
    }) |want| try testing.expect(std.mem.indexOf(u8, keys, want) != null);
    try testing.expectError(error.UnreadableXcodeVersion, dtKeys(gpa, .{ .sdk_version = "1", .sdk_build = "1", .xcodebuild_version = "xcode-select: error", .os_build = "1" }));
}
