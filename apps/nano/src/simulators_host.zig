//! This computer's iOS Simulators (`ListSimulators`, `SetUpSimulators`,
//! `BootSimulator`, `ShutdownSimulator`): the Zig port of
//! `crates/engine/src/simulators/{mod,hub}.rs` for the engine's RPCs.
//!
//! Listing, booting and shutting down use `xcrun simctl` directly.
//! `SetUpSimulators` installs the pinned streaming helper (`expo-device-hub`
//! 0.12.0) under `<data>/tools` with `npm ci --ignore-scripts` from the
//! lockfile shipped in `simulator_helper/`, staged and renamed into place,
//! with a sentinel naming the version and the lockfile's SHA-256.
//!
//! Simulator ids must be the UDID of an iOS Simulator `simctl` lists right
//! now; no other string reaches a command line. Off macOS `ListSimulators`
//! says unsupported and the rest refuse. `HARNESS_SIMULATOR_ALLOWLIST`
//! (comma-separated UDIDs) limits which simulators are listed or accepted.
//!
//! Every external command goes through `proc_seam.Runner`, so tests answer
//! from recorded, made-up `simctl`/`npm` output and never boot anything.
const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const Allocator = std.mem.Allocator;
const proc = @import("proc_seam.zig");

pub const xcrun = "/usr/bin/xcrun";
pub const unsupported = "iOS Simulators need a Mac with Xcode.";
pub const allowlist_env = "HARNESS_SIMULATOR_ALLOWLIST";
pub const simctl_timeout_ms: u64 = 20_000;
pub const boot_timeout_ms: u64 = 120_000;
pub const install_timeout_ms: u64 = 10 * 60_000;
pub const node_missing = "Node.js wasn't found on this computer. Install Node.js 20 or newer, then try again.";
const xcode_missing = "Xcode wasn't found on this computer.";
const xcode_missing_hint = "Xcode wasn't found on this computer. Install Xcode, or select it with xcode-select.";

pub const package = "expo-device-hub";
pub const version = "0.12.0";
pub const package_json = @embedFile("simulator_helper/package.json");
pub const package_lock = @embedFile("simulator_helper/package-lock.json");
pub const host_script = @embedFile("simulator_helper/harness-sim-host.mjs");
pub const host_script_name = "harness-sim-host.mjs";
const middleware_rel = "node_modules/" ++ package ++ "/vendor/serve-sim/dist/middleware.js";
const sentinel_name = ".install-complete";
const min_node_major: u32 = 20;

pub const Device = struct {
    id: []u8,
    name: []u8,
    runtime: []u8,
    booted: bool,

    pub fn deinit(self: *Device, gpa: Allocator) void {
        gpa.free(self.id);
        gpa.free(self.name);
        gpa.free(self.runtime);
    }
};

pub fn freeDevices(gpa: Allocator, devices: []Device) void {
    for (devices) |*d| d.deinit(gpa);
    gpa.free(devices);
}

/// Simulator ids are CoreSimulator UDIDs; anything else never reaches a command line.
pub fn isUdid(id: []const u8) bool {
    if (id.len != 36) return false;
    for (id, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (c != '-') return false;
        } else if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

/// `com.apple.CoreSimulator.SimRuntime.iOS-27-0` → `iOS 27.0`; other platforms → null.
pub fn iosRuntimeAlloc(gpa: Allocator, key: []const u8) !?[]u8 {
    const last = if (std.mem.lastIndexOfScalar(u8, key, '.')) |i| key[i + 1 ..] else key;
    if (!std.mem.startsWith(u8, last, "iOS-")) return null;
    const ver = last["iOS-".len..];
    const out = try std.fmt.allocPrint(gpa, "iOS {s}", .{ver});
    std.mem.replaceScalar(u8, out["iOS ".len..], '-', '.');
    return out;
}

fn versionLess(a: []const u8, b: []const u8) std.math.Order {
    var ia = std.mem.splitScalar(u8, trimIos(a), '.');
    var ib = std.mem.splitScalar(u8, trimIos(b), '.');
    while (true) {
        const pa = nextNum(&ia);
        const pb = nextNum(&ib);
        if (pa == null and pb == null) return .eq;
        if (pa == null) return .lt;
        if (pb == null) return .gt;
        const o = std.math.order(pa.?, pb.?);
        if (o != .eq) return o;
    }
}

fn trimIos(s: []const u8) []const u8 {
    var r = s;
    while (std.mem.startsWith(u8, r, "iOS ")) r = r["iOS ".len..];
    return r;
}

fn nextNum(it: *std.mem.SplitIterator(u8, .scalar)) ?u32 {
    while (it.next()) |p| {
        if (std.fmt.parseInt(u32, p, 10)) |n| return n else |_| continue;
    }
    return null;
}

fn deviceBefore(_: void, a: Device, b: Device) bool {
    if (a.booted != b.booted) return a.booted;
    switch (versionLess(b.runtime, a.runtime)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    return std.mem.order(u8, a.name, b.name) == .lt;
}

pub const ParseError = error{ BadSimctlList, OutOfMemory };

/// `simctl list devices available -j` → iOS devices, booted first, then
/// newest runtime, then by name. Rows without a well-formed UDID are dropped.
pub fn parseDevices(gpa: Allocator, text: []const u8) ParseError![]Device {
    const parsed = json.parseFromSlice(json.Value, gpa, text, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadSimctlList,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.BadSimctlList;
    const devs = parsed.value.object.get("devices") orelse return error.BadSimctlList;
    if (devs != .object) return error.BadSimctlList;
    var out: std.ArrayList(Device) = .empty;
    errdefer {
        for (out.items) |*d| d.deinit(gpa);
        out.deinit(gpa);
    }
    var it = devs.object.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* != .array) return error.BadSimctlList;
        const runtime = try iosRuntimeAlloc(gpa, e.key_ptr.*) orelse continue;
        defer gpa.free(runtime);
        for (e.value_ptr.array.items) |row| {
            if (row != .object) return error.BadSimctlList;
            const udid = strField(row.object, "udid") orelse return error.BadSimctlList;
            const name = strField(row.object, "name") orelse return error.BadSimctlList;
            const state = strField(row.object, "state") orelse return error.BadSimctlList;
            if (!isUdid(udid)) continue;
            const id = try gpa.dupe(u8, udid);
            errdefer gpa.free(id);
            const nm = try gpa.dupe(u8, name);
            errdefer gpa.free(nm);
            const rt = try gpa.dupe(u8, runtime);
            errdefer gpa.free(rt);
            try out.append(gpa, .{ .id = id, .name = nm, .runtime = rt, .booted = std.mem.eql(u8, state, "Booted") });
        }
    }
    std.mem.sort(Device, out.items, {}, deviceBefore);
    return out.toOwnedSlice(gpa);
}

fn strField(obj: json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

/// `v22.3.0` → 22.
pub fn nodeMajor(text: []const u8) ?u32 {
    const t = std.mem.trimStart(u8, std.mem.trim(u8, text, " \t\r\n"), "v");
    const dot = std.mem.indexOfScalar(u8, t, '.') orelse t.len;
    return std.fmt.parseInt(u32, t[0..dot], 10) catch null;
}

/// npm's own reason, and where the rest of its output is.
pub fn npmFailureAlloc(gpa: Allocator, stderr: []const u8, log_path: []const u8) ![]u8 {
    var first_error: ?[]const u8 = null;
    var detail: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, stderr, '\n');
    while (lines.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t\r");
        const rest = if (std.mem.startsWith(u8, l, "npm error "))
            l["npm error ".len..]
        else if (std.mem.startsWith(u8, l, "npm ERR! "))
            l["npm ERR! ".len..]
        else
            continue;
        const msg = std.mem.trim(u8, rest, " \t");
        if (msg.len == 0 or std.mem.startsWith(u8, msg, "A complete log")) continue;
        if (first_error == null) first_error = msg;
        const is_code = std.mem.startsWith(u8, msg, "code ") or std.mem.startsWith(u8, msg, "syscall ") or std.mem.startsWith(u8, msg, "errno ");
        if (detail == null and !is_code) detail = msg;
    }
    var last_line: ?[]const u8 = null;
    if (detail == null and first_error == null) {
        var back = std.mem.splitBackwardsScalar(u8, stderr, '\n');
        while (back.next()) |raw| {
            const l = std.mem.trim(u8, raw, " \t\r");
            if (l.len > 0) {
                last_line = l;
                break;
            }
        }
    }
    const reason = detail orelse first_error orelse last_line orelse "no output";
    return std.fmt.allocPrint(gpa, "npm couldn't install the streaming helper: {s} (full output in {s})", .{ reason, log_path });
}

pub fn lockDigestHex() [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(package_lock, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn sentinelText() [version.len + 1 + 64 + 1]u8 {
    const hex = lockDigestHex();
    return (version ++ "\n").* ++ hex ++ "\n".*;
}

pub const Reply = union(enum) {
    ok: []u8,
    bad_params: []const u8,
    /// Owned by the `Simulators` instance until its next call.
    failed: []const u8,
};

pub const Method = enum { list, set_up, boot, shutdown };

pub const Simulators = struct {
    gpa: Allocator,
    io: ?std.Io,
    runner: proc.Runner,
    /// `<data>/tools`; null when the engine has no data directory.
    tools_dir: ?[]u8 = null,
    supported: bool = builtin.os.tag == .macos,
    allowlist: ?[][]u8 = null,
    /// Where tools are looked up (`PATH` plus Homebrew's and `/usr/local/bin`).
    tool_path: []u8,
    /// Resolved once: Xcode's developer dir when `xcode-select` points somewhere without simctl.
    developer_dir: ?[]u8 = null,
    developer_dir_known: bool = false,
    developer_dir_env_set: bool = false,
    last_err: ?[]u8 = null,

    pub const Options = struct {
        tools_dir: ?[]const u8 = null,
        supported: ?bool = null,
        allowlist: ?[]const u8 = null,
        path_env: ?[]const u8 = null,
        developer_dir_env_set: bool = false,
        /// Also search Homebrew's and `/usr/local/bin` (tests turn this off).
        system_tool_dirs: bool = true,
    };

    pub fn init(gpa: Allocator, io: ?std.Io, runner: proc.Runner, opts: Options) !Simulators {
        var self: Simulators = .{
            .gpa = gpa,
            .io = io,
            .runner = runner,
            .tool_path = undefined,
            .developer_dir_env_set = opts.developer_dir_env_set,
        };
        if (opts.supported) |s| self.supported = s;
        const own = opts.path_env orelse "";
        self.tool_path = if (opts.system_tool_dirs)
            try std.fmt.allocPrint(gpa, "{s}{s}/opt/homebrew/bin:/usr/local/bin", .{ own, if (own.len > 0) ":" else "" })
        else
            try gpa.dupe(u8, own);
        errdefer gpa.free(self.tool_path);
        if (opts.tools_dir) |t| self.tools_dir = try gpa.dupe(u8, t);
        errdefer if (self.tools_dir) |t| gpa.free(t);
        if (opts.allowlist) |raw| self.allowlist = try parseAllowlist(gpa, raw);
        return self;
    }

    pub fn deinit(self: *Simulators) void {
        if (self.tools_dir) |t| self.gpa.free(t);
        if (self.allowlist) |l| {
            for (l) |id| self.gpa.free(id);
            self.gpa.free(l);
        }
        self.gpa.free(self.tool_path);
        if (self.developer_dir) |d| self.gpa.free(d);
        if (self.last_err) |e| self.gpa.free(e);
    }

    fn fail(self: *Simulators, msg: []u8) Reply {
        if (self.last_err) |old| self.gpa.free(old);
        self.last_err = msg;
        return .{ .failed = msg };
    }

    fn failStatic(self: *Simulators, msg: []const u8) !Reply {
        return self.fail(try self.gpa.dupe(u8, msg));
    }

    fn allowed(self: *const Simulators, id: []const u8) bool {
        const list = self.allowlist orelse return true;
        for (list) |a| if (std.ascii.eqlIgnoreCase(a, id)) return true;
        return false;
    }

    /// Run `xcrun simctl <args>`; ok → stdout (owned), else an owned error message.
    fn simctl(self: *Simulators, args: []const []const u8, timeout_ms: u64) !union(enum) { ok: []u8, err: []u8 } {
        try self.resolveDeveloperDir();
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.gpa);
        var env_arg: ?[]u8 = null;
        defer if (env_arg) |e| self.gpa.free(e);
        if (self.developer_dir) |dir| {
            env_arg = try std.fmt.allocPrint(self.gpa, "DEVELOPER_DIR={s}", .{dir});
            try argv.appendSlice(self.gpa, &.{ "/usr/bin/env", env_arg.? });
        }
        try argv.appendSlice(self.gpa, &.{ xcrun, "simctl" });
        try argv.appendSlice(self.gpa, args);
        var out = try self.runner.run(self.gpa, .{ .argv = argv.items, .timeout_ms = timeout_ms });
        defer out.deinit(self.gpa);
        switch (out.term) {
            .timed_out => return .{ .err = try std.fmt.allocPrint(self.gpa, "simctl {s} timed out", .{args[0]}) },
            .spawn_failed => return .{ .err = try self.gpa.dupe(u8, xcode_missing) },
            else => {},
        }
        if (out.ok()) return .{ .ok = try self.gpa.dupe(u8, out.stdout) };
        const stderr = std.mem.trim(u8, out.stderr, " \t\r\n");
        if (std.mem.indexOf(u8, stderr, "unable to find utility") != null) {
            return .{ .err = try self.gpa.dupe(u8, xcode_missing_hint) };
        }
        return .{ .err = try self.gpa.dupe(u8, stderr) };
    }

    fn resolveDeveloperDir(self: *Simulators) !void {
        if (self.developer_dir_known) return;
        self.developer_dir_known = true;
        if (self.developer_dir_env_set) return;
        var found = try self.runner.run(self.gpa, .{ .argv = &.{ xcrun, "--find", "simctl" }, .timeout_ms = simctl_timeout_ms });
        defer found.deinit(self.gpa);
        if (found.ok()) return;
        const io = self.io orelse return;
        const xcode = "/Applications/Xcode.app/Contents/Developer";
        if (isFile(io, xcode ++ "/usr/bin/simctl")) self.developer_dir = try self.gpa.dupe(u8, xcode);
    }

    /// The devices `simctl` lists that the allowlist admits; error → owned message.
    fn devices(self: *Simulators) !union(enum) { ok: []Device, err: []u8 } {
        if (!self.supported) return .{ .err = try self.gpa.dupe(u8, unsupported) };
        const res = try self.simctl(&.{ "list", "devices", "available", "-j" }, simctl_timeout_ms);
        const text = switch (res) {
            .ok => |t| t,
            .err => |e| return .{ .err = e },
        };
        defer self.gpa.free(text);
        const all = parseDevices(self.gpa, text) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.BadSimctlList => return .{ .err = try self.gpa.dupe(u8, "reading simctl's device list: invalid JSON") },
        };
        var keep: usize = 0;
        for (all) |*d| {
            if (self.allowed(d.id)) {
                all[keep] = d.*;
                keep += 1;
            } else d.deinit(self.gpa);
        }
        return .{ .ok = try shrink(self.gpa, all, keep) };
    }

    /// A well-formed, allowed id that `simctl` lists right now; returns its canonical id.
    fn checkKnown(self: *Simulators, id: []const u8) !union(enum) { ok: []u8, err: []u8 } {
        if (!self.supported) return .{ .err = try self.gpa.dupe(u8, unsupported) };
        if (!isUdid(id)) return .{ .err = try std.fmt.allocPrint(self.gpa, "not a simulator id: {f}", .{json.fmt(id, .{})}) };
        if (!self.allowed(id)) return .{ .err = try std.fmt.allocPrint(self.gpa, "no iOS Simulator {s} on this computer", .{id}) };
        const res = try self.devices();
        const devs = switch (res) {
            .ok => |d| d,
            .err => |e| return .{ .err = e },
        };
        defer freeDevices(self.gpa, devs);
        for (devs) |d| {
            if (std.ascii.eqlIgnoreCase(d.id, id)) return .{ .ok = try self.gpa.dupe(u8, d.id) };
        }
        return .{ .err = try std.fmt.allocPrint(self.gpa, "no iOS Simulator {s} on this computer", .{id}) };
    }

    pub fn installDir(self: *const Simulators, gpa: Allocator) !?[]u8 {
        const tools = self.tools_dir orelse return null;
        return try std.fmt.allocPrint(gpa, "{s}/{s}/{s}", .{ tools, package, version });
    }

    pub fn isInstalled(self: *Simulators) bool {
        const io = self.io orelse return false;
        const dir = (self.installDir(self.gpa) catch return false) orelse return false;
        defer self.gpa.free(dir);
        return installedAt(self.gpa, io, dir);
    }

    /// `ListSimulators`.
    pub fn listJson(self: *Simulators) ![]u8 {
        const set_up = self.isInstalled();
        if (!self.supported) return listReply(self.gpa, false, unsupported, set_up, &.{});
        const res = try self.devices();
        switch (res) {
            .ok => |devs| {
                defer freeDevices(self.gpa, devs);
                return listReply(self.gpa, true, null, set_up, devs);
            },
            .err => |e| {
                defer self.gpa.free(e);
                return listReply(self.gpa, false, e, set_up, &.{});
            },
        }
    }

    /// `SetUpSimulators`: install the streaming helper, then list.
    pub fn setUp(self: *Simulators) !Reply {
        if (!self.supported) return self.failStatic(unsupported);
        if (try self.install()) |msg| return self.fail(msg);
        return .{ .ok = try self.listJson() };
    }

    /// `BootSimulator`; booting a booted simulator is a no-op, not a failure.
    pub fn boot(self: *Simulators, id: []const u8) !Reply {
        return self.stateChange(id, "boot", boot_timeout_ms, "current state: Booted");
    }

    /// `ShutdownSimulator`; shutting down a shut-down simulator is a no-op.
    pub fn shutdown(self: *Simulators, id: []const u8) !Reply {
        return self.stateChange(id, "shutdown", simctl_timeout_ms, "current state: Shutdown");
    }

    fn stateChange(self: *Simulators, id: []const u8, verb: []const u8, timeout_ms: u64, benign: []const u8) !Reply {
        const known = try self.checkKnown(id);
        const dev_id = switch (known) {
            .ok => |d| d,
            .err => |e| return self.fail(e),
        };
        defer self.gpa.free(dev_id);
        const res = try self.simctl(&.{ verb, dev_id }, timeout_ms);
        switch (res) {
            .ok => |t| self.gpa.free(t),
            .err => |e| {
                if (std.mem.indexOf(u8, e, benign) == null) return self.fail(e);
                self.gpa.free(e);
            },
        }
        return .{ .ok = try self.gpa.dupe(u8, "{\"ok\":true}") };
    }

    fn findTool(self: *Simulators, name: []const u8) !?[]u8 {
        const io = self.io orelse return null;
        var it = std.mem.splitScalar(u8, self.tool_path, ':');
        while (it.next()) |dir| {
            if (dir.len == 0) continue;
            const candidate = try std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ dir, name });
            if (isFile(io, candidate)) return candidate;
            self.gpa.free(candidate);
        }
        return null;
    }

    /// Install the pinned helper. Returns an owned error message, or null on success.
    pub fn install(self: *Simulators) !?[]u8 {
        const io = self.io orelse return try self.gpa.dupe(u8, "Simulator streaming can't be set up on this engine.");
        const dir = (try self.installDir(self.gpa)) orelse return try self.gpa.dupe(u8, "Simulator streaming can't be set up on this engine.");
        defer self.gpa.free(dir);
        if (installedAt(self.gpa, io, dir)) return null;

        const node = (try self.findTool("node")) orelse return try self.gpa.dupe(u8, node_missing);
        defer self.gpa.free(node);
        {
            var v = try self.runner.run(self.gpa, .{ .argv = &.{ node, "--version" }, .timeout_ms = simctl_timeout_ms });
            defer v.deinit(self.gpa);
            if (v.term == .spawn_failed) return try self.gpa.dupe(u8, node_missing);
            const ver = std.mem.trim(u8, v.stdout, " \t\r\n");
            const major = nodeMajor(ver);
            if (major == null or major.? < min_node_major) {
                return try std.fmt.allocPrint(self.gpa, "Simulator streaming needs Node.js {d} or newer; this computer has {s}.", .{
                    min_node_major,
                    if (ver.len == 0) "an unknown version" else ver,
                });
            }
        }
        const npm = (try self.findTool("npm")) orelse return try self.gpa.dupe(u8, node_missing);
        defer self.gpa.free(npm);

        const parent = std.fs.path.dirname(dir).?;
        std.Io.Dir.cwd().createDirPath(io, parent) catch |e|
            return try std.fmt.allocPrint(self.gpa, "preparing {s}: {s}", .{ parent, @errorName(e) });
        var rnd: [8]u8 = undefined;
        io.random(&rnd);
        const staging = try std.fmt.allocPrint(self.gpa, "{s}/.staging-{x}", .{ parent, rnd });
        defer self.gpa.free(staging);
        std.Io.Dir.cwd().createDirPath(io, staging) catch |e|
            return try std.fmt.allocPrint(self.gpa, "preparing the install: {s}", .{@errorName(e)});
        const result = self.installInto(io, dir, staging, npm);
        std.Io.Dir.cwd().deleteTree(io, staging) catch {};
        return result;
    }

    fn installInto(self: *Simulators, io: std.Io, dir: []const u8, staging: []const u8, npm: []const u8) !?[]u8 {
        const gpa = self.gpa;
        if (writeIn(gpa, io, staging, "package.json", package_json)) |m| return m;
        if (writeIn(gpa, io, staging, "package-lock.json", package_lock)) |m| return m;
        const path_arg = try std.fmt.allocPrint(gpa, "PATH={s}", .{self.tool_path});
        defer gpa.free(path_arg);
        var out = try self.runner.run(gpa, .{
            .argv = &.{ "/usr/bin/env", "npm_config_ignore_scripts=true", path_arg, npm, "ci", "--ignore-scripts", "--omit=dev", "--no-audit", "--no-fund", "--no-update-notifier" },
            .cwd = staging,
            .timeout_ms = install_timeout_ms,
        });
        defer out.deinit(gpa);
        switch (out.term) {
            .timed_out => return try gpa.dupe(u8, "Setting up timed out: npm didn't finish in 10 minutes."),
            .spawn_failed => return try std.fmt.allocPrint(gpa, "Couldn't run npm: {s}", .{out.stderr}),
            else => {},
        }
        const log_path = try std.fmt.allocPrint(gpa, "{s}/simulator-setup.log", .{self.tools_dir.?});
        defer gpa.free(log_path);
        {
            const both = try std.mem.concat(gpa, u8, &.{ out.stdout, out.stderr });
            defer gpa.free(both);
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = log_path, .data = both }) catch {};
        }
        if (!out.ok()) return try npmFailureAlloc(gpa, out.stderr, log_path);

        const pkg_path = try std.fmt.allocPrint(gpa, "{s}/node_modules/{s}/package.json", .{ staging, package });
        defer gpa.free(pkg_path);
        const installed = try readVersion(gpa, io, pkg_path);
        defer if (installed) |v| gpa.free(v);
        if (installed == null or !std.mem.eql(u8, installed.?, version)) {
            return try std.fmt.allocPrint(gpa, "npm installed {s} {s} instead of {s}.", .{ package, installed orelse "nothing", version });
        }
        const mw = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ staging, middleware_rel });
        defer gpa.free(mw);
        if (!isFile(io, mw)) return try gpa.dupe(u8, "npm finished without the streaming helper's files.");
        if (writeIn(gpa, io, staging, host_script_name, host_script)) |m| return m;
        const sentinel = sentinelText();
        if (writeIn(gpa, io, staging, sentinel_name, &sentinel)) |m| return m;
        std.Io.Dir.cwd().deleteTree(io, dir) catch |e| switch (e) {
            else => return try std.fmt.allocPrint(gpa, "replacing the old install: {s}", .{@errorName(e)}),
        };
        std.Io.Dir.rename(std.Io.Dir.cwd(), staging, std.Io.Dir.cwd(), dir, io) catch |e|
            return try std.fmt.allocPrint(gpa, "finishing the install: {s}", .{@errorName(e)});
        return null;
    }
};

fn shrink(gpa: Allocator, all: []Device, keep: usize) ![]Device {
    if (keep == all.len) return all;
    const out = try gpa.alloc(Device, keep);
    @memcpy(out, all[0..keep]);
    gpa.free(all);
    return out;
}

fn writeIn(gpa: Allocator, io: std.Io, dir: []const u8, name: []const u8, data: []const u8) ?[]u8 {
    const path = std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, name }) catch return null;
    defer gpa.free(path);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data }) catch |e| {
        return std.fmt.allocPrint(gpa, "preparing the install: {s}", .{@errorName(e)}) catch null;
    };
    return null;
}

fn isFile(io: std.Io, path: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .file;
}

fn readVersion(gpa: Allocator, io: std.Io, path: []const u8) !?[]u8 {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch return null;
    defer gpa.free(text);
    const parsed = json.parseFromSlice(json.Value, gpa, text, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const v = strField(parsed.value.object, "version") orelse return null;
    return try gpa.dupe(u8, v);
}

pub fn installedAt(gpa: Allocator, io: std.Io, dir: []const u8) bool {
    const sp = std.fmt.allocPrint(gpa, "{s}/" ++ sentinel_name, .{dir}) catch return false;
    defer gpa.free(sp);
    const text = std.Io.Dir.cwd().readFileAlloc(io, sp, gpa, .limited(4096)) catch return false;
    defer gpa.free(text);
    const want = sentinelText();
    if (!std.mem.eql(u8, text, &want)) return false;
    const mw = std.fmt.allocPrint(gpa, "{s}/" ++ middleware_rel, .{dir}) catch return false;
    defer gpa.free(mw);
    return isFile(io, mw);
}

pub fn parseAllowlist(gpa: Allocator, raw: []const u8) ![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |s| gpa.free(s);
        out.deinit(gpa);
    }
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |part| {
        const t = std.mem.trim(u8, part, " \t\r\n");
        if (t.len == 0) continue;
        const up = try std.ascii.allocUpperString(gpa, t);
        try out.append(gpa, up);
    }
    return out.toOwnedSlice(gpa);
}

/// `SimulatorList` (camelCase): `{supported, reason, setUp, devices}`.
pub fn listReply(gpa: Allocator, supported: bool, reason: ?[]const u8, set_up: bool, devices: []const Device) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.print("{{\"supported\":{},\"reason\":{f},\"setUp\":{},\"devices\":[", .{ supported, json.fmt(reason, .{}), set_up });
    for (devices, 0..) |d, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"id\":{f},\"name\":{f},\"runtime\":{f},\"booted\":{}}}", .{
            json.fmt(d.id, .{}), json.fmt(d.name, .{}), json.fmt(d.runtime, .{}), d.booted,
        });
    }
    try w.writeAll("]}");
    return aw.toOwnedSlice();
}

/// Dispatch one simulator RPC (`params` as sent); a success body is allocated with `reply_gpa`.
pub fn handle(sims: *Simulators, reply_gpa: Allocator, method: Method, params: json.Value) !Reply {
    const r = try handleInner(sims, method, params);
    switch (r) {
        .ok => |body| {
            defer sims.gpa.free(body);
            return .{ .ok = try reply_gpa.dupe(u8, body) };
        },
        else => return r,
    }
}

fn handleInner(sims: *Simulators, method: Method, params: json.Value) !Reply {
    switch (method) {
        .list => return .{ .ok = try sims.listJson() },
        .set_up => return sims.setUp(),
        .boot, .shutdown => {
            if (params != .object) return .{ .bad_params = "expected object" };
            const v = params.object.get("simulatorId") orelse return .{ .bad_params = "missing field `simulatorId`" };
            if (v != .string) return .{ .bad_params = "invalid type for `simulatorId`, expected a string" };
            return if (method == .boot) sims.boot(v.string) else sims.shutdown(v.string);
        },
    }
}

// ---- the engine's shared instance ----

var shared_state: ?Simulators = null;
var shared_runner: proc.SystemRunner = undefined;

/// The engine's simulators (state lives for the process, outside the RPC allocator).
pub fn shared(io: ?std.Io, data_dir: ?[]const u8) !*Simulators {
    if (shared_state) |*s| return s;
    const gpa = std.heap.smp_allocator;
    var runner: proc.Runner = .{ .run_fn = noSpawn };
    if (io) |i| {
        shared_runner = .{ .io = i };
        runner = shared_runner.runner();
    }
    var tools: ?[]u8 = null;
    defer if (tools) |t| gpa.free(t);
    if (data_dir) |d| tools = try std.fmt.allocPrint(gpa, "{s}/tools", .{std.mem.trimEnd(u8, d, "/")});
    shared_state = try Simulators.init(gpa, io, runner, .{
        .tools_dir = tools,
        .allowlist = proc.getenv(allowlist_env),
        .path_env = proc.getenv("PATH"),
        .developer_dir_env_set = proc.getenv("DEVELOPER_DIR") != null,
    });
    return &shared_state.?;
}

fn noSpawn(_: ?*anyopaque, gpa: Allocator, _: proc.Request) Allocator.Error!proc.Output {
    return .{ .term = .spawn_failed, .stdout = try gpa.dupe(u8, ""), .stderr = try gpa.dupe(u8, "") };
}

/// Map a `Reply` onto the engine's `RpcOutcome`.
pub fn toOutcome(comptime Outcome: type, r: Reply) Outcome {
    return switch (r) {
        .ok => |body| .{ .unary_json = body },
        .bad_params => |m| .{ .err = .{ .bad_params = m } },
        .failed => |m| .{ .err = .{ .exec_error = m } },
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const SIM = "6BBA9FD8-EFAD-45B7-B9FC-30715804D2A1";
const OTHER = "11111111-2222-3333-4444-555555555555";

/// Recorded, made-up `simctl list devices available -j` output.
const simctl_list_fixture =
    \\{"devices":{
    \\ "com.apple.CoreSimulator.SimRuntime.iOS-26-2":[
    \\  {"udid":"11111111-1111-1111-1111-111111111111","name":"iPhone 16","state":"Shutdown","isAvailable":true}],
    \\ "com.apple.CoreSimulator.SimRuntime.iOS-27-0":[
    \\  {"udid":"22222222-2222-2222-2222-222222222222","name":"iPhone 17","state":"Shutdown","isAvailable":true},
    \\  {"udid":"33333333-3333-3333-3333-333333333333","name":"iPhone 17 Pro","state":"Booted","isAvailable":true},
    \\  {"udid":"not-a-udid","name":"Odd","state":"Booted","isAvailable":true}],
    \\ "com.apple.CoreSimulator.SimRuntime.watchOS-12-0":[
    \\  {"udid":"44444444-4444-4444-4444-444444444444","name":"Watch","state":"Booted","isAvailable":true}]
    \\}}
;

const two_sims_fixture = "{\"devices\":{\"com.apple.CoreSimulator.SimRuntime.iOS-27-0\":[" ++
    "{\"udid\":\"" ++ SIM ++ "\",\"name\":\"Test A\",\"state\":\"Booted\"}," ++
    "{\"udid\":\"" ++ OTHER ++ "\",\"name\":\"Test B\",\"state\":\"Shutdown\"}]}}";

fn testSims(fake: *proc.FakeRunner, opts: Simulators.Options) !Simulators {
    var o = opts;
    if (o.supported == null) o.supported = true;
    return Simulators.init(testing.allocator, null, fake.runner(), o);
}

test "simctl list becomes iOS devices, booted first, newest runtime next" {
    const devs = try parseDevices(testing.allocator, simctl_list_fixture);
    defer freeDevices(testing.allocator, devs);
    try testing.expectEqual(@as(usize, 3), devs.len);
    try testing.expectEqualStrings("iPhone 17 Pro", devs[0].name);
    try testing.expectEqualStrings("iOS 27.0", devs[0].runtime);
    try testing.expect(devs[0].booted);
    try testing.expectEqualStrings("iPhone 17", devs[1].name);
    try testing.expectEqualStrings("iPhone 16", devs[2].name);
    try testing.expectEqualStrings("iOS 26.2", devs[2].runtime);
    try testing.expectError(error.BadSimctlList, parseDevices(testing.allocator, "{\"nope\":1}"));
}

test "only UDIDs reach command lines" {
    try testing.expect(isUdid(SIM));
    for ([_][]const u8{
        "",                                         "booted", "all", "../../etc",
        SIM ++ "/x",                                SIM ++ " --set",
        "6BBA9FD8xEFADx45B7xB9FCx30715804D2A1",     "6BBA9FD8-EFAD-45B7-B9FC-30715804D2AZ",
        "-BBA9FD8-EFAD-45B7-B9FC-30715804D2A1",
    }) |bad| try testing.expect(!isUdid(bad));
}

test "the allowlist seam parses UDIDs case-insensitively" {
    const ids = try parseAllowlist(testing.allocator, " 6bba9fd8-efad-45b7-b9fc-30715804d2a1, ," ++ OTHER);
    defer {
        for (ids) |i| testing.allocator.free(i);
        testing.allocator.free(ids);
    }
    try testing.expectEqual(@as(usize, 2), ids.len);
    try testing.expectEqualStrings(SIM, ids[0]);
}

test "ListSimulators: devices from simctl, filtered by the allowlist" {
    var fake = proc.FakeRunner.init(testing.allocator, &.{
        .{ .prefix = "/usr/bin/xcrun --find simctl", .stdout = "/x/simctl\n" },
        .{ .prefix = "/usr/bin/xcrun simctl list devices available -j", .stdout = two_sims_fixture },
    });
    defer fake.deinit();
    var sims = try testSims(&fake, .{ .allowlist = SIM });
    defer sims.deinit();
    const body = try sims.listJson();
    defer testing.allocator.free(body);
    try testing.expectEqualStrings(
        "{\"supported\":true,\"reason\":null,\"setUp\":false,\"devices\":[{\"id\":\"" ++ SIM ++ "\",\"name\":\"Test A\",\"runtime\":\"iOS 27.0\",\"booted\":true}]}",
        body,
    );
}

test "ListSimulators: unsupported off macOS, and simctl's failure as the reason" {
    var fake = proc.FakeRunner.init(testing.allocator, &.{
        .{ .prefix = "/usr/bin/xcrun --find simctl", .code = 1 },
        .{ .prefix = "/usr/bin/xcrun simctl list", .code = 72, .stderr = "xcrun: error: unable to find utility \"simctl\"\n" },
    });
    defer fake.deinit();
    var off = try testSims(&fake, .{ .supported = false });
    defer off.deinit();
    const a = try off.listJson();
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("{\"supported\":false,\"reason\":\"iOS Simulators need a Mac with Xcode.\",\"setUp\":false,\"devices\":[]}", a);
    try testing.expectEqual(@as(usize, 0), fake.calls.items.len);

    var on = try testSims(&fake, .{});
    defer on.deinit();
    const b = try on.listJson();
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("{\"supported\":false,\"reason\":\"Xcode wasn't found on this computer. Install Xcode, or select it with xcode-select.\",\"setUp\":false,\"devices\":[]}", b);
}

test "BootSimulator boots a listed simulator and treats already-booted as done" {
    var fake = proc.FakeRunner.init(testing.allocator, &.{
        .{ .prefix = "/usr/bin/xcrun --find simctl", .stdout = "/x\n" },
        .{ .prefix = "/usr/bin/xcrun simctl list", .stdout = two_sims_fixture },
        .{ .prefix = "/usr/bin/xcrun simctl boot " ++ SIM },
        .{ .prefix = "/usr/bin/xcrun simctl boot " ++ SIM, .code = 149, .stderr = "Unable to boot device in current state: Booted" },
        .{ .prefix = "/usr/bin/xcrun simctl boot " ++ OTHER, .code = 1, .stderr = "Unable to boot: the disk is full" },
    });
    defer fake.deinit();
    var sims = try testSims(&fake, .{});
    defer sims.deinit();
    const p = try json.parseFromSlice(json.Value, testing.allocator, "{\"simulatorId\":\"" ++ SIM ++ "\"}", .{});
    defer p.deinit();
    const r1 = try handle(&sims, testing.allocator, .boot, p.value);
    defer testing.allocator.free(r1.ok);
    try testing.expectEqualStrings("{\"ok\":true}", r1.ok);
    const r2 = try handle(&sims, testing.allocator, .boot, p.value);
    defer testing.allocator.free(r2.ok);
    try testing.expectEqualStrings("{\"ok\":true}", r2.ok);
    try testing.expectEqual(@as(usize, 2), fake.called("simctl boot " ++ SIM));

    const lower = try json.parseFromSlice(json.Value, testing.allocator, "{\"simulatorId\":\"11111111-2222-3333-4444-555555555555\"}", .{});
    defer lower.deinit();
    const r3 = try handle(&sims, testing.allocator, .boot, lower.value);
    try testing.expectEqualStrings("Unable to boot: the disk is full", r3.failed);
}

test "Boot/Shutdown error replies: bad params, malformed id, unknown and disallowed simulators" {
    var fake = proc.FakeRunner.init(testing.allocator, &.{
        .{ .prefix = "/usr/bin/xcrun --find simctl", .stdout = "/x\n" },
        .{ .prefix = "/usr/bin/xcrun simctl list", .stdout = two_sims_fixture },
    });
    defer fake.deinit();
    var sims = try testSims(&fake, .{ .allowlist = SIM });
    defer sims.deinit();
    try testing.expectEqualStrings("missing field `simulatorId`", (try handle(&sims, testing.allocator, .boot, .{ .object = .empty })).bad_params);
    try testing.expectEqualStrings("expected object", (try handle(&sims, testing.allocator, .shutdown, .null)).bad_params);

    const bad = try json.parseFromSlice(json.Value, testing.allocator, "{\"simulatorId\":\"booted\"}", .{});
    defer bad.deinit();
    try testing.expectEqualStrings("not a simulator id: \"booted\"", (try handle(&sims, testing.allocator, .boot, bad.value)).failed);

    const other = try json.parseFromSlice(json.Value, testing.allocator, "{\"simulatorId\":\"" ++ OTHER ++ "\"}", .{});
    defer other.deinit();
    try testing.expectEqualStrings("no iOS Simulator " ++ OTHER ++ " on this computer", (try handle(&sims, testing.allocator, .shutdown, other.value)).failed);

    const unknown = try json.parseFromSlice(json.Value, testing.allocator, "{\"simulatorId\":\"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE\"}", .{});
    defer unknown.deinit();
    var open = try testSims(&fake, .{});
    defer open.deinit();
    try testing.expectEqualStrings("no iOS Simulator AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE on this computer", (try handle(&open, testing.allocator, .shutdown, unknown.value)).failed);
    try testing.expectEqual(@as(usize, 0), fake.called("simctl shutdown"));

    var off = try testSims(&fake, .{ .supported = false });
    defer off.deinit();
    const sim = try json.parseFromSlice(json.Value, testing.allocator, "{\"simulatorId\":\"" ++ SIM ++ "\"}", .{});
    defer sim.deinit();
    try testing.expectEqualStrings(unsupported, (try handle(&off, testing.allocator, .boot, sim.value)).failed);
    try testing.expectEqualStrings(unsupported, (try handle(&off, testing.allocator, .set_up, .null)).failed);
}

test "the shipped lockfile pins the helper and the sentinel names its hash" {
    const lock = try json.parseFromSlice(json.Value, testing.allocator, package_lock, .{});
    defer lock.deinit();
    const pkgs = lock.value.object.get("packages").?.object;
    try testing.expectEqualStrings(version, pkgs.get("node_modules/" ++ package).?.object.get("version").?.string);
    const s = sentinelText();
    try testing.expect(std.mem.startsWith(u8, &s, version ++ "\n"));
    try testing.expectEqual(@as(usize, version.len + 66), s.len);
}

test "npm failures name npm's own reason and the log" {
    const msg = try npmFailureAlloc(testing.allocator, "npm error code E404\nnpm error 404 Not Found - GET https://registry.example/x\nnpm error A complete log of this run\n", "/t/log");
    defer testing.allocator.free(msg);
    try testing.expectEqualStrings("npm couldn't install the streaming helper: 404 Not Found - GET https://registry.example/x (full output in /t/log)", msg);
    try testing.expectEqual(@as(?u32, 22), nodeMajor("v22.3.0\n"));
    try testing.expectEqual(@as(?u32, null), nodeMajor(""));
}

const NpmEffect = struct {
    fn writeInstall(_: ?*anyopaque, req: proc.Request) void {
        const io = testing.io;
        const cwd = req.cwd.?;
        var buf: [1024]u8 = undefined;
        const mw_dir = std.fmt.bufPrint(&buf, "{s}/node_modules/expo-device-hub/vendor/serve-sim/dist", .{cwd}) catch return;
        std.Io.Dir.cwd().createDirPath(io, mw_dir) catch return;
        var b2: [1024]u8 = undefined;
        const mw = std.fmt.bufPrint(&b2, "{s}/middleware.js", .{mw_dir}) catch return;
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = mw, .data = "// made up\n" }) catch return;
        var b3: [1024]u8 = undefined;
        const pj = std.fmt.bufPrint(&b3, "{s}/node_modules/expo-device-hub/package.json", .{cwd}) catch return;
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = pj, .data = "{\"name\":\"expo-device-hub\",\"version\":\"0.12.0\"}" }) catch return;
    }
};

fn makeTools(tmp: *std.testing.TmpDir) ![]u8 {
    const io = testing.io;
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const bin = try std.fmt.allocPrint(testing.allocator, "{s}/bin", .{root});
    defer testing.allocator.free(bin);
    try std.Io.Dir.cwd().createDirPath(io, bin);
    for ([_][]const u8{ "node", "npm" }) |t| {
        const p = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ bin, t });
        defer testing.allocator.free(p);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = "#!/bin/sh\n" });
    }
    return testing.allocator.dupe(u8, root);
}

test "SetUpSimulators installs the pinned helper once, then lists with setUp true" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try makeTools(&tmp);
    defer testing.allocator.free(root);
    const tools = try std.fmt.allocPrint(testing.allocator, "{s}/tools", .{root});
    defer testing.allocator.free(tools);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/bin", .{root});
    defer testing.allocator.free(path);

    var fake = proc.FakeRunner.init(testing.allocator, &.{
        .{ .prefix = "/usr/bin/xcrun --find simctl", .stdout = "/x\n" },
        .{ .prefix = "/usr/bin/xcrun simctl list", .stdout = two_sims_fixture },
        .{ .prefix = path, .stdout = "v22.1.0\n" },
        .{ .prefix = "/usr/bin/env npm_config_ignore_scripts=true", .stdout = "added 12 packages\n", .effect = NpmEffect.writeInstall },
    });
    defer fake.deinit();
    var sims = try Simulators.init(testing.allocator, testing.io, fake.runner(), .{ .tools_dir = tools, .supported = true, .path_env = path, .system_tool_dirs = false });
    defer sims.deinit();
    const r = try handle(&sims, testing.allocator, .set_up, .null);
    defer testing.allocator.free(r.ok);
    try testing.expect(std.mem.indexOf(u8, r.ok, "\"setUp\":true") != null);
    try testing.expect(std.mem.indexOf(u8, r.ok, "\"supported\":true") != null);
    try testing.expect(sims.isInstalled());
    try testing.expectEqual(@as(usize, 1), fake.called(" ci --ignore-scripts --omit=dev"));
    // Already installed: no second npm run.
    const again = try handle(&sims, testing.allocator, .set_up, .null);
    defer testing.allocator.free(again.ok);
    try testing.expectEqual(@as(usize, 1), fake.called(" ci --ignore-scripts"));
}

test "SetUpSimulators error replies: no node, old node, npm failure, wrong version" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try makeTools(&tmp);
    defer testing.allocator.free(root);
    const tools = try std.fmt.allocPrint(testing.allocator, "{s}/tools", .{root});
    defer testing.allocator.free(tools);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/bin", .{root});
    defer testing.allocator.free(path);
    {
        var fake = proc.FakeRunner.init(testing.allocator, &.{});
        defer fake.deinit();
        var sims = try Simulators.init(testing.allocator, testing.io, fake.runner(), .{ .tools_dir = tools, .supported = true, .path_env = "/nonexistent-dir", .system_tool_dirs = false });
        defer sims.deinit();
        try testing.expectEqualStrings(node_missing, (try handle(&sims, testing.allocator, .set_up, .null)).failed);
        try testing.expectEqual(@as(usize, 0), fake.calls.items.len);
    }
    {
        var fake = proc.FakeRunner.init(testing.allocator, &.{.{ .prefix = path, .stdout = "v18.2.0\n" }});
        defer fake.deinit();
        var sims = try Simulators.init(testing.allocator, testing.io, fake.runner(), .{ .tools_dir = tools, .supported = true, .path_env = path, .system_tool_dirs = false });
        defer sims.deinit();
        try testing.expectEqualStrings("Simulator streaming needs Node.js 20 or newer; this computer has v18.2.0.", (try handle(&sims, testing.allocator, .set_up, .null)).failed);
    }
    {
        var fake = proc.FakeRunner.init(testing.allocator, &.{
            .{ .prefix = path, .stdout = "v22.0.0\n" },
            .{ .prefix = "/usr/bin/env npm_config_ignore_scripts=true", .code = 1, .stderr = "npm error code EINTEGRITY\nnpm error sha512 mismatch\n" },
        });
        defer fake.deinit();
        var sims = try Simulators.init(testing.allocator, testing.io, fake.runner(), .{ .tools_dir = tools, .supported = true, .path_env = path, .system_tool_dirs = false });
        defer sims.deinit();
        const m = (try handle(&sims, testing.allocator, .set_up, .null)).failed;
        try testing.expect(std.mem.startsWith(u8, m, "npm couldn't install the streaming helper: sha512 mismatch (full output in "));
        try testing.expect(!sims.isInstalled());
    }
    {
        var fake = proc.FakeRunner.init(testing.allocator, &.{
            .{ .prefix = path, .stdout = "v22.0.0\n" },
            .{ .prefix = "/usr/bin/env npm_config_ignore_scripts=true" },
        });
        defer fake.deinit();
        var sims = try Simulators.init(testing.allocator, testing.io, fake.runner(), .{ .tools_dir = tools, .supported = true, .path_env = path, .system_tool_dirs = false });
        defer sims.deinit();
        try testing.expectEqualStrings("npm installed expo-device-hub nothing instead of 0.12.0.", (try handle(&sims, testing.allocator, .set_up, .null)).failed);
    }
}
