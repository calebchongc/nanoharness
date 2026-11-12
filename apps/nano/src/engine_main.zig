//! `harness-engine` — the Zig headless engine daemon & CLI (`apps/harness/src/main.rs`).
//!
//! The engine the desktop app starts (engine_start.zig) and the service a
//! daemon runs; it replaces the Rust `harness headless`:
//! - `headless` (or no args): takes `{data_dir}/engine.lock`, binds
//!   `ws://127.0.0.1:{HARNESS_IPC_PORT|27664}`, upgrades bare WebSocket clients
//!   (rejecting browser `Origin:` headers), and serves JSON-RPC calls and live
//!   `Watch*` streams through `EngineHost`.
//! - `status`, `sync`, `login`, `logout`: engine_cli.zig.
//! - `mcp`: runs the stdio JSON-RPC 2.0 MCP server (`mcp_server.zig`).
//! - `daemon install|uninstall|start|stop|restart|status`: engine_daemon.zig
//!   (`launchd` on macOS, `systemd` on Linux).
const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const Io = std.Io;
const net = Io.net;
const Allocator = std.mem.Allocator;
const build_info = @import("build_info");
const acp_host = @import("acp_host.zig");
const auth_host = @import("auth_host.zig");
const docs_store = @import("docs_store.zig");
const engine_mod = @import("engine.zig");
const engine_host = @import("engine_host.zig");
const mcp_server = @import("mcp_server.zig");
const ws = @import("ws.zig");
const ws_server = @import("ws_server.zig");
const engine_cli = @import("engine_cli.zig");
const engine_daemon = @import("engine_daemon.zig");
const updates_host = @import("updates_host.zig");

/// The folder a terminal started the engine in, if it names one to show as a
/// project: not the filesystem root a service or Finder launch reports.
pub fn defaultSpacePath(pwd: ?[]const u8) ?[]const u8 {
    const p = pwd orelse return null;
    if (p.len == 0 or std.mem.eql(u8, p, "/") or std.mem.eql(u8, p, "\\")) return null;
    if (!std.fs.path.isAbsolute(p)) return null;
    return p;
}

/// Where graff may be when `GRAFF_EXECUTABLE` isn't set, in order: the copy
/// Harness keeps current (`~/.harness/bin/graff`), then the one shipped
/// beside this engine: `Contents/Resources/bin` in the macOS bundle, the
/// same folder elsewhere. The Rust launcher seeded the first from the second;
/// starting from the bundle's copy keeps a fresh install working without it.
pub fn graffCandidates(arena: Allocator, home: ?[]const u8, exe_dir: ?[]const u8) ![]const []const u8 {
    const name = if (builtin.os.tag == .windows) "graff.exe" else "graff";
    var out: std.ArrayList([]const u8) = .empty;
    if (home) |h| if (h.len > 0) try out.append(arena, try std.fs.path.join(arena, &.{ h, ".harness", "bin", name }));
    if (exe_dir) |d| {
        try out.append(arena, try std.fs.path.join(arena, &.{ d, "..", "Resources", "bin", name }));
        try out.append(arena, try std.fs.path.join(arena, &.{ d, name }));
    }
    return out.toOwnedSlice(arena);
}

/// Set up this engine's updater at start-up, as the Rust engine spawns its
/// `Updater` with the engine: managed and app installs start their release
/// check now, not on the first update call. Call once auth (the edge URL)
/// is configured.
pub fn startUpdateChecks(host: *engine_host.EngineHost) void {
    _ = updates_host.forEngine(engine_host.EngineHost, host) catch |err| {
        std.log.warn("harness-engine: update checks not started: {t}", .{err});
    };
}

test "the updater is set up when the engine starts, before any update call" {
    updates_host.resetForTests();
    defer updates_host.resetForTests();
    var host = try engine_host.EngineHost.init(std.testing.allocator, "dev-start", "Synthetic");
    defer host.deinit();
    host.io = std.testing.io;
    try std.testing.expect(!updates_host.configured());
    startUpdateChecks(&host);
    try std.testing.expect(updates_host.configured());
    try std.testing.expectEqual(@as(?*anyopaque, &host), updates_host.configuredHost());
}

test "no default project without a real starting folder; never a hard-coded one" {
    try std.testing.expectEqual(@as(?[]const u8, null), defaultSpacePath(null));
    try std.testing.expectEqual(@as(?[]const u8, null), defaultSpacePath("/"));
    try std.testing.expectEqual(@as(?[]const u8, null), defaultSpacePath(""));
    try std.testing.expectEqual(@as(?[]const u8, null), defaultSpacePath("relative/dir"));
    try std.testing.expectEqualStrings("/work/synthetic", defaultSpacePath("/work/synthetic").?);
}

test "graff: the kept copy first, then the one shipped beside the engine" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const got = try graffCandidates(arena_state.allocator(), "/Users/synthetic", "/Applications/Harness.app/Contents/MacOS");
    const sep = std.fs.path.sep_str;
    try std.testing.expectEqual(@as(usize, 3), got.len);
    try std.testing.expectEqualStrings("/Users/synthetic" ++ sep ++ ".harness" ++ sep ++ "bin" ++ sep ++ "graff", got[0]);
    try std.testing.expectEqualStrings("/Applications/Harness.app/Contents/MacOS" ++ sep ++ ".." ++ sep ++ "Resources" ++ sep ++ "bin" ++ sep ++ "graff", got[1]);
    const none = try graffCandidates(arena_state.allocator(), null, null);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const port = engine_mod.Engine.portFrom(init.environ_map);

    const raw_argv = try init.minimal.args.toSlice(init.arena.allocator());
    const argv = try init.arena.allocator().alloc([]const u8, raw_argv.len);
    for (raw_argv, argv) |r, *a| a.* = r;
    const command = engine_cli.parse(if (argv.len > 0) argv[1..] else argv) catch |err| {
        var ebuf: [256]u8 = undefined;
        var ew = Io.File.stderr().writerStreaming(io, &ebuf);
        ew.interface.print("harness-engine: {s}\n\n{s}", .{ switch (err) {
            error.UnknownCommand => "unknown command",
            error.MissingDaemonAction => "daemon needs an action",
            error.UnknownDaemonAction => "unknown daemon action",
            error.UnexpectedArgument => "unexpected argument",
        }, engine_cli.usage }) catch {};
        ew.interface.flush() catch {};
        std.process.exit(2);
    };

    if (command != .headless and command != .mcp) {
        var obuf: [4096]u8 = undefined;
        var ow = Io.File.stdout().writerStreaming(io, &obuf);
        const out = &ow.interface;
        var ibuf: [4096]u8 = undefined;
        var ir = Io.File.stdin().readerStreaming(io, &ibuf);
        const ctx: engine_cli.Context = .{
            .gpa = gpa,
            .io = io,
            .env = init.environ_map,
            .port = port,
            .out = out,
            .in = &ir.interface,
            .interactive = Io.File.stdin().isTty(io) catch false,
        };
        const code: u8 = switch (command) {
            .headless, .mcp => unreachable,
            .version => blk: {
                try out.print("harness-engine {s}\n", .{build_info.version});
                break :blk 0;
            },
            .help => blk: {
                try out.writeAll(engine_cli.usage);
                break :blk 0;
            },
            .status => try engine_cli.status(ctx),
            .sync => try engine_cli.sync(ctx),
            .login => try engine_cli.login(ctx),
            .logout => try engine_cli.logout(ctx),
            .update => blk: {
                const dir: ?[]u8 = engine_cli.resolveDataDir(gpa, io, init.environ_map) catch null;
                defer if (dir) |d| gpa.free(d);
                var ebuf: [1024]u8 = undefined;
                var ew = Io.File.stderr().writerStreaming(io, &ebuf);
                defer ew.interface.flush() catch {};
                const edge = engine_cli.AuthEnv.from(init.environ_map).edge_url;
                break :blk try updates_host.runUpdateCommand(gpa, io, edge, dir, out, &ew.interface);
            },
            .daemon => |action| blk: {
                const dir = try engine_cli.resolveDataDir(gpa, io, init.environ_map);
                defer gpa.free(dir);
                break :blk try engine_daemon.main(gpa, io, init.environ_map, dir, action, out);
            },
        };
        out.flush() catch {};
        if (code != 0) std.process.exit(code);
        return;
    }
    if (command == .mcp) {
        try mcp_server.serveStdio(gpa, io, init.environ_map);
        return;
    }

    const resolved_data_dir: ?[]const u8 = engine_cli.resolveDataDir(init.arena.allocator(), io, init.environ_map) catch |err| engine_cli.fatalStart(io, "no data directory ({t}): set HOME or HARNESS_DATA_DIR", .{err});
    // One engine per data folder, as the Rust engine's `InstanceLock`: two
    // would each rewrite the same session and stores.
    var instance_lock: ?engine_cli.InstanceLock = null;
    defer if (instance_lock) |*l| l.release(io);
    if (resolved_data_dir) |data_dir| instance_lock = engine_cli.lockEngineOrExit(gpa, io, data_dir);

    const persisted_dev_id = try engine_host.loadOrCreateDeviceId(gpa, io, resolved_data_dir);
    defer gpa.free(persisted_dev_id);
    const detected_dev_name = try engine_host.detectDeviceName(gpa, init.environ_map);
    defer gpa.free(detected_dev_name);

    var host = try engine_host.EngineHost.init(gpa, persisted_dev_id, detected_dev_name);
    defer host.deinit();
    host.io = io;
    host.ensureLocalDeviceRow();
    host.agent_accounts.configureFromEnv(init.environ_map) catch {};
    if (init.environ_map.get("GRAFF_EXECUTABLE")) |ge| {
        if (ge.len > 0) host.graff_exe = ge;
    } else {
        const exe_dir = std.process.executableDirPathAlloc(io, init.arena.allocator()) catch null;
        const list = graffCandidates(init.arena.allocator(), init.environ_map.get("HOME"), exe_dir) catch &.{};
        for (list) |gpath| {
            if (std.Io.Dir.cwd().access(io, gpath, .{})) |_| {
                host.graff_exe = gpath;
                break;
            } else |_| {}
        }
    }
    if (host.graff_exe) |ge| {
        host.cached_graff_models_json = acp_host.discoverGraffModelsJson(gpa, io, ge) catch null;
    }

    if (resolved_data_dir) |data_dir| {
        if (data_dir.len > 0) {
            host.setDataDir(data_dir) catch {};
            if (std.fmt.allocPrintSentinel(gpa, "{s}/docs.sqlite", .{data_dir}, 0)) |db_path_z| {
                defer gpa.free(db_path_z);
                if (docs_store.DocsStore.openSqlite(gpa, db_path_z.ptr)) |sqlite_store| {
                    host.store.deinit();
                    host.store = sqlite_store;
                } else |_| {}
            } else |_| {}
        }
    }

    // Configure real CodeGraff OAuth/PKCE + device sign-in (`apps/harness/src/main.rs`),
    // unless `HARNESS_AUTH_DISABLED=1` or an explicit `HARNESS_EDGE_TOKEN` dev override is set.
    try host.setBotsEnvOverride(init.environ_map.get("GRAFF_BOTS"));
    const auth_env = engine_cli.AuthEnv.from(init.environ_map);
    const auth_disabled = auth_env.disabled;
    if (auth_env.codegraffEnabled()) {
        try host.auth.configureCodegraff(auth_env.edge_url, auth_env.client_id, auth_env.api_base, resolved_data_dir);
        try host.auth.setCodegraffGateway(auth_env.gateway);
        if (init.environ_map.get("HARNESS_CALLBACK_PORT")) |p_str| {
            if (std.fmt.parseInt(u16, p_str, 10)) |cb_port| {
                host.auth.callback_port = cb_port;
            } else |_| {}
        }
        if (init.environ_map.get("CODEGRAFF_API_KEY")) |env_key| {
            const trimmed_key = std.mem.trim(u8, env_key, " \t\r\n");
            if (trimmed_key.len > 0) {
                host.auth.adoptCodegraffKey(null, trimmed_key, null) catch {};
            }
        }
        if (host.auth.loadPersistedSession(io)) {
            host.workspace_scope = "synced";
            // Zero-network-latency startup: hydrate spaces, chats, devices, and
            // `registry_seq` from local SSD cache (`registry-cache.json`) in <0.5 ms;
            // the live background sync worker below immediately catches up via `?since=seq`.
            _ = host.loadPersistedRegistryCache(io);
        } else {
            host.workspace_scope = "local";
        }
    } else {
        // No CodeGraff (a development bearer, or auth turned off): the
        // development scope, as the Rust engine without a client id.
        try @import("dev_edge_auth.zig").configure(&host.auth, io, auth_env, init.environ_map.get("HARNESS_ORG_ID"), resolved_data_dir);
        host.workspace_scope = engine_cli.startScope(auth_env, false).name();
        if (@import("loro.zig").enabled and host.auth.signed_in) {
            // Full document replicas now exist on non-host devices too.
            // Restore registry ownership before considering saved documents;
            // a replica's SQLite snapshot does not make it the chat's host.
            _ = host.loadPersistedRegistryCache(io);
        }
    }

    // Seed any persisted chats from docs.sqlite into host.chats so they appear in the sidebar and sync outbound.
    var snap_it = host.store.snapshots.iterator();
    while (snap_it.next()) |entry| {
        const cid = entry.key_ptr.*;
        var exists = false;
        for (host.chats.items) |c| {
            if (std.mem.eql(u8, c.id, cid)) {
                exists = true;
                break;
            }
        }
        if (!exists and @import("loro.zig").enabled) {
            // Preserve an unreferenced replica on disk; wait for its registry
            // row rather than claiming another device's chat after restart.
            const doc = try host.getOrCreateDoc(cid);
            _ = doc;
            continue;
        }
        if (!exists) {
            const id_copy = try gpa.dupe(u8, cid);
            errdefer gpa.free(id_copy);
            const dev_copy = try gpa.dupe(u8, host.device_id);
            errdefer gpa.free(dev_copy);
            const h_copy = try gpa.dupe(u8, "graff");
            errdefer gpa.free(h_copy);

            var title_copy: ?[]u8 = null;
            errdefer if (title_copy) |t| gpa.free(t);
            var preview_copy: ?[]u8 = null;
            errdefer if (preview_copy) |p| gpa.free(p);
            var created_ms: i64 = host.nowMs();
            var last_msg_ms: i64 = created_ms;

            if (host.getOrCreateDoc(cid)) |doc| {
                if (doc.messages.items.len > 0) {
                    const first_m = doc.messages.items[0];
                    if (first_m.created_at > 0) created_ms = first_m.created_at;
                    const last_m = doc.messages.items[doc.messages.items.len - 1];
                    if (last_m.created_at > 0) last_msg_ms = last_m.created_at;
                    for (first_m.parts.items) |pt| {
                        if (std.mem.eql(u8, pt.kind, "text") and pt.text.items.len > 0) {
                            const trimmed = std.mem.trim(u8, pt.text.items, " \t\r\n");
                            const nl = std.mem.indexOfAny(u8, trimmed, "\r\n") orelse trimmed.len;
                            const first_line = trimmed[0..@min(nl, @as(usize, 64))];
                            if (first_line.len > 0) title_copy = gpa.dupe(u8, first_line) catch null;
                            break;
                        }
                    }
                    if (doc.latestTextPreview(140)) |pv| {
                        preview_copy = gpa.dupe(u8, pv) catch null;
                    }
                }
            } else |_| {}

            try host.chats.append(gpa, .{
                .id = id_copy,
                .space_id = null,
                .device_id = dev_copy,
                .harness = h_copy,
                .title = title_copy,
                .preview = preview_copy,
                .created_at_ms = created_ms,
                .last_message_at_ms = last_msg_ms,
                .last_prompt_at_ms = created_ms,
            });
        }
        host.markChatTailDirty(cid);
    }
    host.ensureLocalDeviceRow();

    // A placeholder project for the folder an engine was started in from a
    // terminal. A service or the app starts it with no such folder: then it
    // has no projects until one is added, as the Rust engine.
    const default_space = if (host.spaces.items.len == 0) defaultSpacePath(init.environ_map.get("PWD")) else null;
    if (default_space) |default_path| {
        const id_copy = try gpa.dupe(u8, "space-zig-default");
        errdefer gpa.free(id_copy);
        const dev_copy = try gpa.dupe(u8, host.device_id);
        errdefer gpa.free(dev_copy);
        const path_copy = try gpa.dupe(u8, default_path);
        errdefer gpa.free(path_copy);
        const name_copy = try gpa.dupe(u8, std.fs.path.basename(default_path));
        errdefer gpa.free(name_copy);
        try host.spaces.append(gpa, .{
            .id = id_copy,
            .device_id = dev_copy,
            .path = path_copy,
            .name = name_copy,
            .git_detected = engine_cli.gitDetected(io, default_path),
        });
    }

    startUpdateChecks(&host);

    const listen_addr = try net.IpAddress.parseIp4("127.0.0.1", port);
    var server = try listen_addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    std.log.info("harness-engine (zig): listening on ws://127.0.0.1:{d}", .{port});

    if (!auth_disabled) {
        host.bg_sync_enabled = true;

        const WarmAccountsWorker = struct {
            gpa: Allocator,
            io: Io,
            host: *engine_host.EngineHost,

            fn run(ctx: @This()) void {
                defer _ = ctx.host.bg_workers_active.fetchSub(1, .release);
                if (ctx.host.stop_requested) return;
                if (ctx.host.agent_accounts.listAgentAccountsJson(ctx.io, ctx.host.nowMs(), true)) |snap| {
                    ctx.gpa.free(snap);
                } else |_| {}
            }
        };
        _ = host.bg_workers_active.fetchAdd(1, .acquire);
        if (std.Thread.spawn(.{}, WarmAccountsWorker.run, .{WarmAccountsWorker{ .gpa = gpa, .io = io, .host = &host }})) |wth| {
            wth.detach();
        } else |_| {
            _ = host.bg_workers_active.fetchSub(1, .release);
        }

        const BgSyncWorker = struct {
            io: Io,
            host: *engine_host.EngineHost,

            fn run(ctx: @This()) void {
                defer _ = ctx.host.bg_workers_active.fetchSub(1, .release);
                var last_wake = ctx.host.sync_wake_seq.load(.acquire);
                var bot_tick_cycles: usize = 0;
                if (!ctx.host.stop_requested) {
                    _ = ctx.host.syncFromEdgeRegistryUnlocked(ctx.io);
                    @import("loro_sync.zig").sync(ctx.host, ctx.io) catch |err| std.log.warn("Loro sync: {s}", .{@errorName(err)});
                    if (!ctx.host.stop_requested) {
                        ctx.host.prefetchRecentChatTailsUnlocked(ctx.io, 16);
                    }
                    if (!ctx.host.stop_requested) {
                        ctx.host.tickBotsUnlocked(ctx.io);
                    }
                }
                while (!ctx.host.stop_requested) {
                    var step: usize = 0;
                    while (step < 25 and !ctx.host.stop_requested) : (step += 1) {
                        if (ctx.host.sync_wake_seq.load(.acquire) != last_wake) break;
                        std.Io.sleep(ctx.io, .fromMilliseconds(100), .awake) catch return;
                    }
                    if (ctx.host.stop_requested) break;
                    last_wake = ctx.host.sync_wake_seq.load(.acquire);
                    if (ctx.host.syncFromEdgeRegistryUnlocked(ctx.io) and !ctx.host.stop_requested) {
                        ctx.host.prefetchRecentChatTailsUnlocked(ctx.io, 16);
                    }
                    @import("loro_sync.zig").sync(ctx.host, ctx.io) catch |err| std.log.warn("Loro sync: {s}", .{@errorName(err)});
                    bot_tick_cycles += 1;
                    if (bot_tick_cycles >= 24 and !ctx.host.stop_requested) {
                        bot_tick_cycles = 0;
                        ctx.host.tickBotsUnlocked(ctx.io);
                    }
                }
            }
        };
        _ = host.bg_workers_active.fetchAdd(1, .acquire);
        if (std.Thread.spawn(.{}, BgSyncWorker.run, .{BgSyncWorker{ .io = io, .host = &host }})) |sth| {
            sth.detach();
        } else |_| {
            _ = host.bg_workers_active.fetchSub(1, .release);
        }
    }

    const device_relay = @import("relay_engine.zig").start(gpa, io, &host);
    defer if (device_relay) |r| r.stop();

    @import("engine_accept.zig").serve(gpa, io, &server, &host, serveSocket);
}

const PongWriter = struct {
    host: *engine_host.EngineHost,
    w: *Io.Writer,
    fn send(self: @This(), payload: []const u8) void {
        if (self.host.io) |io| self.host.mutex.lockUncancelable(io);
        defer if (self.host.io) |io| self.host.mutex.unlock(io);
        ws_server.writeServerFrame(self.w, .pong, payload) catch return;
        self.w.flush() catch {};
    }
};

pub fn serveSocket(gpa: Allocator, io: Io, host: *engine_host.EngineHost, stream: *net.Stream) !void {
    auth_host.setTcpNoDelay(stream.*);
    var rbuf: [64 * 1024]u8 = undefined;
    var wbuf: [64 * 1024]u8 = undefined;
    var rd = net.Stream.Reader.init(stream.*, io, &rbuf);
    var wr = net.Stream.Writer.init(stream.*, io, &wbuf);

    try ws_server.acceptHandshake(&rd.interface, &wr.interface);
    defer host.removeClientWatches(&wr.interface);

    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(gpa);

    var req_arena = std.heap.ArenaAllocator.init(gpa);
    defer req_arena.deinit();

    while (true) {
        const op = ws.readMessageFrom(gpa, &rd.interface, &msg, PongWriter{ .host = host, .w = &wr.interface }, PongWriter.send) catch |err| switch (err) {
            error.PeerClosed, error.EndOfStream => return,
            else => return err,
        };
        if (op != .text) continue;

        var lines = std.mem.splitScalar(u8, msg.items, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;
            defer _ = req_arena.reset(.{ .retain_with_limit = 64 * 1024 });
            try dispatchClientLineWithArena(gpa, req_arena.allocator(), host, &wr.interface, line);
            if (host.stop_requested) return;
        }
    }
}

pub fn flushPushedWatchFrames(gpa: Allocator, host: *engine_host.EngineHost, w: *Io.Writer) !void {
    if (host.pushed_frames.items.len == 0) return;
    defer {
        for (host.pushed_frames.items) |*p| p.deinit(gpa);
        host.pushed_frames.clearRetainingCapacity();
    }
    for (host.pushed_frames.items) |pushed| {
        const frame = try std.fmt.allocPrint(gpa, "{{\"id\":{d},\"item\":{s}}}", .{ pushed.sub_id, pushed.item_json });
        defer gpa.free(frame);
        try ws_server.writeServerFrame(w, .text, frame);
    }
    try w.flush();
}

pub fn dispatchClientLine(gpa: Allocator, host: *engine_host.EngineHost, w: *Io.Writer, line: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    return dispatchClientLineWithArena(gpa, arena.allocator(), host, w, line);
}

pub fn dispatchClientLineWithArena(
    gpa: Allocator,
    scratch: Allocator,
    host: *engine_host.EngineHost,
    w: *Io.Writer,
    line: []const u8,
) !void {
    if (host.io) |io| host.mutex.lockUncancelable(io);
    defer if (host.io) |io| host.mutex.unlock(io);
    if (host.io != null) host.held_for_dispatch = true;
    defer host.held_for_dispatch = false;

    const parsed_val = json.parseFromSliceLeaky(json.Value, scratch, line, .{}) catch return;
    if (parsed_val != .object) return;
    const obj = parsed_val.object;
    const id_val = obj.get("id") orelse return;
    if (id_val != .integer) return;
    const id: u64 = @intCast(@max(0, id_val.integer));

    if (obj.get("cancel")) |c| {
        if (c == .bool and c.bool) {
            host.cancelWatch(id);
            return;
        }
    }

    const method_val = obj.get("method") orelse return;
    if (method_val != .string) return;
    const params_val = obj.get("params") orelse json.Value{ .object = .empty };

    if (std.mem.eql(u8, method_val.string, "ListAgentAccounts") and
        host.io != null and
        (host.auth.codegraff_client_id != null or host.agent_accounts.home_dir != null))
    {
        const io = host.io.?;
        const force_usage: bool = if (params_val == .object)
            (if (params_val.object.get("forceUsage")) |fv| (if (fv == .bool) fv.bool else true) else true)
        else
            true;
        const now_ms = host.nowMs();
        host.mutex.unlock(io);
        const acc_res = host.agent_accounts.listAgentAccountsJson(io, now_ms, force_usage);
        host.mutex.lockUncancelable(io);
        if (host.stop_requested) {
            if (acc_res) |body| gpa.free(body) else |_| {}
            return;
        }
        if (acc_res) |body| {
            defer gpa.free(body);
            const frame = try std.fmt.allocPrint(scratch, "{{\"id\":{d},\"ok\":{s}}}", .{ id, body });
            try ws_server.writeServerFrame(w, .text, frame);
            try w.flush();
        } else |err| {
            const frame = try std.fmt.allocPrint(scratch, "{{\"id\":{d},\"err\":{f}}}", .{ id, json.fmt(@errorName(err), .{}) });
            try ws_server.writeServerFrame(w, .text, frame);
            try w.flush();
        }
        try flushPushedWatchFrames(gpa, host, w);
        return;
    }

    host.live_ws_writer = w;
    defer host.live_ws_writer = null;

    var outcome = try host.handleWithId(id, method_val.string, params_val);
    switch (outcome) {
        .unary_json => |body| {
            defer gpa.free(body);
            const frame = try std.fmt.allocPrint(scratch, "{{\"id\":{d},\"ok\":{s}}}", .{ id, body });
            try ws_server.writeServerFrame(w, .text, frame);
            try w.flush();
        },
        .stream_items_json => |*st| {
            defer st.deinit(gpa);
            if (st.checked) {
                const ready = try std.fmt.allocPrint(scratch, "{{\"id\":{d},\"ok\":{{\"stream\":true}}}}", .{id});
                try ws_server.writeServerFrame(w, .text, ready);
            }
            for (st.items) |it| {
                const frame = try std.fmt.allocPrint(scratch, "{{\"id\":{d},\"item\":{s}}}", .{ id, it });
                try ws_server.writeServerFrame(w, .text, frame);
            }
            try w.flush();
        },
        .err => |e| {
            const msg = switch (e) {
                .bad_params => |m| m,
                .unknown_method => |m| m,
                .exec_error => |m| m,
            };
            const frame = try std.fmt.allocPrint(scratch, "{{\"id\":{d},\"err\":{f}}}", .{ id, json.fmt(msg, .{}) });
            try ws_server.writeServerFrame(w, .text, frame);
            try w.flush();
        },
    }
    try flushPushedWatchFrames(gpa, host, w);
}

/// A simctl that blocks until the test lets it go (5 s at most), then fails.
const BlockingSimctl = struct {
    entered: Io.Event = .unset,
    release: Io.Event = .unset,

    fn runner(self: *BlockingSimctl) @import("proc_seam.zig").Runner {
        return .{ .ctx = self, .run_fn = run };
    }

    fn run(ctx: ?*anyopaque, a: Allocator, _: @import("proc_seam.zig").Request) Allocator.Error!@import("proc_seam.zig").Output {
        const self: *BlockingSimctl = @ptrCast(@alignCast(ctx.?));
        self.entered.set(std.testing.io);
        self.release.waitTimeout(std.testing.io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } }) catch {};
        return .{ .term = .exited, .code = 1, .stdout = try a.dupe(u8, ""), .stderr = try a.dupe(u8, "synthetic simctl failure") };
    }
};

fn dispatchOne(host: *engine_host.EngineHost, line: []const u8, out: *Io.Writer.Allocating, done: *Io.Event) void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    dispatchClientLineWithArena(std.testing.allocator, arena.allocator(), host, &out.writer, line) catch {};
    done.set(std.testing.io);
}

test "a simulator boot runs outside the engine lock: other requests are answered meanwhile" {
    const sims = @import("simulators_host.zig");
    const io = std.testing.io;
    var simctl: BlockingSimctl = .{};
    sims.setSharedForTests(try sims.Simulators.init(std.testing.allocator, io, simctl.runner(), .{ .supported = true, .system_tool_dirs = false }));
    defer sims.setSharedForTests(null);
    var host = try engine_host.EngineHost.init(std.testing.allocator, "dev-lock", "Synthetic");
    defer host.deinit();
    host.io = io;

    var boot_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer boot_out.deinit();
    var boot_done: Io.Event = .unset;
    const boot = try std.Thread.spawn(.{}, dispatchOne, .{ &host, "{\"id\":1,\"method\":\"BootSimulator\",\"params\":{\"simulatorId\":\"00000000-0000-0000-0000-000000000001\"}}", &boot_out, &boot_done });
    try simctl.entered.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });

    // simctl is still running: another client's request must not wait for it.
    var quick_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer quick_out.deinit();
    var quick_done: Io.Event = .unset;
    const quick = try std.Thread.spawn(.{}, dispatchOne, .{ &host, "{\"id\":2,\"method\":\"GetAutonomy\",\"params\":{}}", &quick_out, &quick_done });
    const answered = if (quick_done.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } })) true else |_| false;
    simctl.release.set(io);
    quick.join();
    boot.join();
    try std.testing.expect(answered);
    try std.testing.expect(boot_done.isSet());
    try std.testing.expect(std.mem.indexOf(u8, quick_out.written(), "\"id\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, boot_out.written(), "\"id\":1") != null);
    // The lock is back with nobody: a direct call can take it.
    host.mutex.lockUncancelable(io);
    host.mutex.unlock(io);
    try std.testing.expect(!host.held_for_dispatch);
}
