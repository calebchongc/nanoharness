//! Crash and hang reports from iOS (MetricKit), as the Swift app's
//! CrashReports.swift keeps them. iOS hands the app a report on a later
//! launch for each crash, hang, CPU or disk-write overuse and slow launch it
//! saw. They're kept on the phone (newest 50, `Application Support/
//! CrashReports`, `<ms>-<sha256 prefix>.json`), and each is sent once to the
//! edge (`POST /diagnostics/crash-reports`, a JSON array, at most 10 reports
//! and about 900 KB a request) while signed in, unless "Send to Harness" is
//! off (`crashReports.send` in NSUserDefaults, on unless turned off).
//!
//! The rules are pure functions tested here; `runtime` is the iOS side.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const keep: usize = 50;
pub const batch_count: usize = 10;
pub const batch_bytes: usize = 900_000;
pub const send_key = "crashReports.send";
pub const sent_list = "sent.list";
pub const folder_name = "CrashReports";

// ── Rules ────────────────────────────────────────────────────────────────

/// The first six bytes of the report's SHA-256, hex: the same report handed
/// over again gets the same name, and is kept once.
pub fn digestHex(data: []const u8) [12]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &hash, .{});
    return std.fmt.bytesToHex(hash[0..6].*, .lower);
}

pub fn fileName(buf: []u8, now_ms: i64, digest: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{d}-{s}.json", .{ now_ms, digest });
}

pub fn isReport(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".json");
}

pub fn alreadySaved(names: []const []const u8, digest: []const u8) bool {
    var suffix_buf: [32]u8 = undefined;
    const suffix = std.fmt.bufPrint(&suffix_buf, "-{s}.json", .{digest}) catch return false;
    for (names) |n| if (std.mem.endsWith(u8, n, suffix)) return true;
    return false;
}

fn newerFirst(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .gt;
}

/// Report names newest first (names start with their millisecond stamp).
pub fn sortNewestFirst(names: [][]const u8) void {
    std.mem.sort([]const u8, names, {}, newerFirst);
}

/// The reports past the newest `keep`, to delete. `names` newest first.
pub fn pruned(names: []const []const u8) []const []const u8 {
    return if (names.len > keep) names[keep..] else names[0..0];
}

/// Upload batches as index ranges into `sizes` (oldest first): at most
/// `count` reports and about `bytes` each; a report bigger than that goes
/// alone (and the edge refuses it with 413).
pub fn batches(gpa: Allocator, sizes: []const usize, count: usize, bytes: usize) ![]const [2]usize {
    var out: std.ArrayList([2]usize) = .empty;
    errdefer out.deinit(gpa);
    var start: usize = 0;
    var size: usize = 0;
    for (sizes, 0..) |s, i| {
        const n = i - start;
        if (n > 0 and (n == count or size + s > bytes)) {
            try out.append(gpa, .{ start, i });
            start = i;
            size = 0;
        }
        size += s + 1;
    }
    if (start < sizes.len) try out.append(gpa, .{ start, sizes.len });
    return out.toOwnedSlice(gpa);
}

/// A JSON array of the reports as iOS wrote them.
pub fn body(gpa: Allocator, reports: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.append(gpa, '[');
    for (reports, 0..) |r, i| {
        if (i > 0) try out.append(gpa, ',');
        try out.appendSlice(gpa, r);
    }
    try out.append(gpa, ']');
    return out.toOwnedSlice(gpa);
}

/// 200: taken. 413: a report the edge will never take; dropping it beats
/// resending it every launch. Anything else: the rest waits for next time.
pub fn markSentAfter(status: u16) bool {
    return status == 200 or status == 413;
}

/// sent.list: the report names the edge took, one per line.
pub fn isSent(sent_text: []const u8, name: []const u8) bool {
    var lines = std.mem.tokenizeAny(u8, sent_text, "\r\n");
    while (lines.next()) |line| if (std.mem.eql(u8, line, name)) return true;
    return false;
}

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, item)) return true;
    return false;
}

/// sent.list again: what was sent and is still on the phone, sorted.
pub fn sentListText(gpa: Allocator, sent: []const []const u8, present: []const []const u8) ![]u8 {
    var keepers: std.ArrayList([]const u8) = .empty;
    defer keepers.deinit(gpa);
    for (sent) |s| {
        if (!contains(present, s) or contains(keepers.items, s)) continue;
        try keepers.append(gpa, s);
    }
    std.mem.sort([]const u8, keepers.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return std.mem.join(gpa, "\n", keepers.items);
}

pub const Summary = struct {
    crashes: usize = 0,
    hangs: usize = 0,
    cpu: usize = 0,
    disk_writes: usize = 0,
    launches: usize = 0,
    /// The first diagnostic's `appBuildVersion`.
    build: ?[]const u8 = null,
    headline: []const u8 = "Diagnostics",
};

/// What a report holds, for the Crash reports list. Strings point into
/// `arena`-owned memory.
pub fn summary(arena: Allocator, data: []const u8) Summary {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, data, .{}) catch return .{};
    if (root != .object) return .{};
    const list = struct {
        fn get(o: std.json.ObjectMap, key: []const u8) []const std.json.Value {
            const v = o.get(key) orelse return &.{};
            return if (v == .array) v.array.items else &.{};
        }
        fn meta(item: ?std.json.Value) ?std.json.ObjectMap {
            const it = item orelse return null;
            if (it != .object) return null;
            const m = it.object.get("diagnosticMetaData") orelse return null;
            return if (m == .object) m.object else null;
        }
        fn str(m: ?std.json.ObjectMap, key: []const u8) ?[]const u8 {
            const v = (m orelse return null).get(key) orelse return null;
            return if (v == .string) v.string else null;
        }
        fn first(items: []const std.json.Value) ?std.json.Value {
            return if (items.len > 0) items[0] else null;
        }
    };
    const o = root.object;
    const crashes = list.get(o, "crashDiagnostics");
    const hangs = list.get(o, "hangDiagnostics");
    const cpu = list.get(o, "cpuExceptionDiagnostics");
    const disk = list.get(o, "diskWriteExceptionDiagnostics");
    const launches = list.get(o, "appLaunchDiagnostics");
    var s: Summary = .{ .crashes = crashes.len, .hangs = hangs.len, .cpu = cpu.len, .disk_writes = disk.len, .launches = launches.len };
    const first = list.first(crashes) orelse list.first(hangs) orelse list.first(cpu) orelse list.first(disk) orelse list.first(launches);
    s.build = list.str(list.meta(first), "appBuildVersion");
    if (list.first(crashes)) |crash| {
        s.headline = crashHeadline(arena, list.meta(crash));
    } else if (list.first(hangs)) |hang| {
        s.headline = if (list.str(list.meta(hang), "hangDuration")) |d| std.fmt.allocPrint(arena, "Hang ({s})", .{d}) catch "Hang" else "Hang";
    } else if (cpu.len > 0) {
        s.headline = "Too much CPU in the background";
    } else if (disk.len > 0) {
        s.headline = "Heavy disk writes";
    } else if (list.first(launches)) |launch| {
        s.headline = if (list.str(list.meta(launch), "launchDuration")) |d| std.fmt.allocPrint(arena, "Slow launch ({s})", .{d}) catch "Slow launch" else "Slow launch";
    }
    return s;
}

/// The watchdog's own words when there are some, otherwise the exception
/// and signal.
pub fn crashHeadline(arena: Allocator, meta: ?std.json.ObjectMap) []const u8 {
    const m = meta orelse return "Crash";
    if (m.get("terminationReason")) |r| if (r == .string) {
        var lines = std.mem.tokenizeAny(u8, r.string, "\r\n");
        if (lines.next()) |line| {
            const view = std.unicode.Utf8View.init(line) catch return "Crash";
            var it = view.iterator();
            var count: usize = 0;
            var cut: usize = line.len;
            while (it.nextCodepointSlice()) |cp| : (count += 1) {
                if (count == 89) cut = @intFromPtr(cp.ptr) - @intFromPtr(line.ptr);
            }
            if (count > 90) return std.fmt.allocPrint(arena, "Crash: {s}…", .{line[0..cut]}) catch "Crash";
            return std.fmt.allocPrint(arena, "Crash: {s}", .{line}) catch "Crash";
        }
    };
    const exception: ?[]const u8 = if (m.get("exceptionType")) |v| (if (v == .integer) exceptionName(arena, v.integer) else null) else null;
    const signal: ?[]const u8 = if (m.get("signal")) |v| (if (v == .integer) signalName(arena, v.integer) else null) else null;
    if (exception != null and signal != null) return std.fmt.allocPrint(arena, "Crash: {s} · {s}", .{ exception.?, signal.? }) catch "Crash";
    if (exception orelse signal) |one| return std.fmt.allocPrint(arena, "Crash: {s}", .{one}) catch "Crash";
    return "Crash";
}

pub fn signalName(arena: Allocator, n: i64) []const u8 {
    return switch (n) {
        4 => "SIGILL",
        5 => "SIGTRAP",
        6 => "SIGABRT",
        9 => "SIGKILL",
        10 => "SIGBUS",
        11 => "SIGSEGV",
        else => std.fmt.allocPrint(arena, "signal {d}", .{n}) catch "signal",
    };
}

pub fn exceptionName(arena: Allocator, n: i64) []const u8 {
    return switch (n) {
        1 => "EXC_BAD_ACCESS",
        2 => "EXC_BAD_INSTRUCTION",
        3 => "EXC_ARITHMETIC",
        6 => "EXC_BREAKPOINT",
        10 => "EXC_CRASH",
        11 => "EXC_RESOURCE",
        12 => "EXC_GUARD",
        else => std.fmt.allocPrint(arena, "exception {d}", .{n}) catch "exception",
    };
}

// ── The folder ───────────────────────────────────────────────────────────

/// Report file names in `folder`, newest first (owned by `arena`).
pub fn listReports(arena: Allocator, io: Io, folder: []const u8) [][]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var dir = Io.Dir.cwd().openDir(io, folder, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file or !isReport(entry.name)) continue;
        names.append(arena, arena.dupe(u8, entry.name) catch continue) catch continue;
    }
    sortNewestFirst(names.items);
    return names.items;
}

/// Writes each report once, then keeps the newest `keep`.
pub fn save(gpa: Allocator, io: Io, folder: []const u8, reports: []const []const u8, now_ms: i64) void {
    if (reports.len == 0) return;
    Io.Dir.cwd().createDirPath(io, folder) catch return;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (reports) |data| {
        const digest = digestHex(data);
        if (alreadySaved(listReports(arena, io, folder), &digest)) continue;
        var name_buf: [64]u8 = undefined;
        const name = fileName(&name_buf, now_ms, &digest) catch continue;
        const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ folder, name }) catch continue;
        Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data }) catch {};
    }
    for (pruned(listReports(arena, io, folder))) |old| {
        const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ folder, old }) catch continue;
        Io.Dir.cwd().deleteFile(io, path) catch {};
    }
}

/// Sends every saved report the edge hasn't taken, oldest first, through
/// `post` (status or null); a failure leaves the rest for next time.
pub fn upload(gpa: Allocator, io: Io, folder: []const u8, post: anytype) void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const list_path = std.fmt.allocPrint(arena, "{s}/{s}", .{ folder, sent_list }) catch return;
    const sent_text = Io.Dir.cwd().readFileAlloc(io, list_path, arena, .limited(1 << 20)) catch "";
    var sent: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.tokenizeAny(u8, sent_text, "\r\n");
    while (lines.next()) |l| sent.append(arena, l) catch return;

    const newest_first = listReports(arena, io, folder);
    var waiting_names: std.ArrayList([]const u8) = .empty;
    var waiting_data: std.ArrayList([]const u8) = .empty;
    var sizes: std.ArrayList(usize) = .empty;
    var i = newest_first.len;
    while (i > 0) {
        i -= 1;
        const name = newest_first[i];
        if (isSent(sent_text, name)) continue;
        const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ folder, name }) catch return;
        const data = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 << 20)) catch continue;
        waiting_names.append(arena, name) catch return;
        waiting_data.append(arena, data) catch return;
        sizes.append(arena, data.len) catch return;
    }
    const ranges = batches(arena, sizes.items, batch_count, batch_bytes) catch return;
    for (ranges) |r| {
        const payload = body(arena, waiting_data.items[r[0]..r[1]]) catch return;
        const status = post.send(payload) orelse return;
        if (!markSentAfter(status)) return;
        sent.appendSlice(arena, waiting_names.items[r[0]..r[1]]) catch return;
        const text = sentListText(arena, sent.items, listReports(arena, io, folder)) catch return;
        Io.Dir.cwd().writeFile(io, .{ .sub_path = list_path, .data = text }) catch return;
    }
}

// ── iOS ──────────────────────────────────────────────────────────────────

pub const runtime = struct {
    const nanoui = @import("nanoui");
    const objc = nanoui.objc;
    const engine_host = @import("engine_host.zig");
    const ios_edge = @import("ios_edge.zig");

    var gpa: Allocator = undefined;
    var io: Io = undefined;
    var host: ?*engine_host.EngineHost = null;
    var folder_buf: [1024]u8 = undefined;
    var folder: []const u8 = "";
    var uploading = std.atomic.Value(bool).init(false);
    var subscriber: ?objc.Object = null;

    /// At launch: the reports iOS has been holding, every later one, and an
    /// upload once signed in.
    pub fn start(allocator: Allocator, rio: Io, h: *engine_host.EngineHost, home: []const u8) void {
        gpa = allocator;
        io = rio;
        host = h;
        folder = std.fmt.bufPrint(&folder_buf, "{s}/Library/Application Support/{s}", .{ home, folder_name }) catch return;
        const cls = objc.defineClass(.{
            .name = "HarnessMetricSubscriber",
            .protocols = &.{"MXMetricManagerSubscriber"},
            .methods = &.{
                .{ .name = "didReceiveDiagnosticPayloads:", .imp = &didReceive, .types = "v@:@" },
            },
        });
        const obj = objc.msg(objc.Object, objc.msg(objc.Object, cls, "alloc", .{}), "init", .{});
        subscriber = obj;
        const manager = objc.msg(objc.Object, objc.class("MXMetricManager"), "sharedManager", .{});
        objc.msg(void, manager, "addSubscriber:", .{obj});
        savePayloads(objc.msg(?objc.Object, manager, "pastDiagnosticPayloads", .{}));
        uploadWhenSignedIn();
    }

    /// The Simulator check (`HARNESS_IOS_SELFTEST=crash-reports`): MetricKit
    /// took the subscriber, and a synthetic report is saved once, listed and
    /// removed. MetricKit itself hands the Simulator no payloads.
    pub fn selfTest() []const u8 {
        if (subscriber == null or folder.len == 0) return "failed: not started";
        const manager = objc.msg(?objc.Object, objc.class("MXMetricManager"), "sharedManager", .{}) orelse return "failed: no MXMetricManager";
        _ = manager;
        const synthetic = "{\"crashDiagnostics\":[{\"diagnosticMetaData\":{\"appBuildVersion\":\"selftest\",\"signal\":11}}]}";
        save(gpa, io, folder, &.{ synthetic, synthetic }, nowMs());
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const digest = digestHex(synthetic);
        var found: usize = 0;
        for (listReports(arena, io, folder)) |name| {
            if (!std.mem.endsWith(u8, name, ".json") or std.mem.indexOf(u8, name, &digest) == null) continue;
            found += 1;
            const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ folder, name }) catch continue;
            const data = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch return "failed: unreadable";
            if (!std.mem.eql(u8, summary(arena, data).headline, "Crash: SIGSEGV")) return "failed: summary";
            Io.Dir.cwd().deleteFile(io, path) catch return "failed: delete";
        }
        return if (found == 1) "ok" else "failed: saved more or less than once";
    }

    fn didReceive(_: objc.Object, _: objc.SEL, payloads: objc.Object) callconv(.c) void {
        savePayloads(payloads);
        uploadWhenSignedIn();
    }

    /// Each MXDiagnosticPayload's `JSONRepresentation`, saved.
    fn savePayloads(list: ?objc.Object) void {
        const payloads = list orelse return;
        const count = objc.msg(usize, payloads, "count", .{});
        if (count == 0) return;
        var datas: std.ArrayList([]const u8) = .empty;
        defer datas.deinit(gpa);
        for (0..count) |i| {
            const payload = objc.msg(objc.Object, payloads, "objectAtIndex:", .{i});
            const data = objc.msg(?objc.Object, payload, "JSONRepresentation", .{}) orelse continue;
            const len = objc.msg(usize, data, "length", .{});
            const bytes = objc.msg([*]const u8, data, "bytes", .{});
            datas.append(gpa, bytes[0..len]) catch return;
        }
        save(gpa, io, folder, datas.items, nowMs());
    }

    fn nowMs() i64 {
        return @intCast(Io.Clock.real.now(io).toMilliseconds());
    }

    pub fn sending() bool {
        const d = objc.msg(objc.Object, objc.class("NSUserDefaults"), "standardUserDefaults", .{});
        if (objc.msg(?objc.Object, d, "objectForKey:", .{objc.nsString(send_key)}) == null) return true;
        return objc.msg(bool, d, "boolForKey:", .{objc.nsString(send_key)});
    }

    /// One run at a time, off the main thread; it waits up to ten minutes
    /// for a sign-in.
    fn uploadWhenSignedIn() void {
        if (!sending()) return;
        if (uploading.swap(true, .acquire)) return;
        const th = std.Thread.spawn(.{}, run, .{}) catch {
            uploading.store(false, .release);
            return;
        };
        th.detach();
    }

    const Poster = struct {
        creds: *const ios_edge.Creds,
        url: []const u8,
        pub fn send(p: Poster, payload: []const u8) ?u16 {
            return ios_edge.send(gpa, io, "POST", p.url, p.creds.token, payload);
        }
    };

    fn run() void {
        defer uploading.store(false, .release);
        const h = host orelse return;
        var waited: usize = 0;
        while (!@atomicLoad(bool, &h.auth.signed_in, .monotonic)) : (waited += 1) {
            if (waited >= 300 or h.stop_requested) return;
            Io.sleep(io, .fromMilliseconds(2000), .awake) catch return;
        }
        var creds = ios_edge.snapshot(gpa, h) orelse return;
        defer creds.deinit(gpa);
        const url = std.fmt.allocPrint(gpa, "{s}/diagnostics/crash-reports", .{creds.edge}) catch return;
        defer gpa.free(url);
        upload(gpa, io, folder, Poster{ .creds = &creds, .url = url });
    }
};

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "a report's name: its stamp and digest, kept once, newest 50" {
    const d = digestHex("{\"crashDiagnostics\":[]}");
    try testing.expectEqual(@as(usize, 12), d.len);
    var buf: [64]u8 = undefined;
    const name = try fileName(&buf, 1794300000123, &d);
    try testing.expect(std.mem.startsWith(u8, name, "1794300000123-"));
    try testing.expect(isReport(name));
    try testing.expect(!isReport(sent_list));
    try testing.expect(alreadySaved(&.{ "1-aaaaaaaaaaaa.json", name }, &d));
    try testing.expect(!alreadySaved(&.{"1-aaaaaaaaaaaa.json"}, &d));

    var names: [52][]const u8 = undefined;
    var name_bufs: [52][16]u8 = undefined;
    for (0..52) |i| names[i] = try std.fmt.bufPrint(&name_bufs[i], "{d}-x.json", .{1000 + i});
    sortNewestFirst(&names);
    try testing.expectEqualStrings("1051-x.json", names[0]);
    const gone = pruned(&names);
    try testing.expectEqual(@as(usize, 2), gone.len);
    try testing.expectEqualStrings("1001-x.json", gone[0]);
    try testing.expectEqualStrings("1000-x.json", gone[1]);
}

test "batches: ten reports or about 900 KB a request, an oversized one alone" {
    const gpa = testing.allocator;
    const twelve: [12]usize = @splat(10);
    const a = try batches(gpa, &twelve, batch_count, batch_bytes);
    defer gpa.free(a);
    try testing.expectEqual(@as(usize, 2), a.len);
    try testing.expectEqual([2]usize{ 0, 10 }, a[0]);
    try testing.expectEqual([2]usize{ 10, 12 }, a[1]);

    const sizes = [_]usize{ 400_000, 400_000, 400_000, 2_000_000, 10 };
    const b = try batches(gpa, &sizes, batch_count, batch_bytes);
    defer gpa.free(b);
    try testing.expectEqual(@as(usize, 4), b.len);
    try testing.expectEqual([2]usize{ 0, 2 }, b[0]);
    try testing.expectEqual([2]usize{ 2, 3 }, b[1]);
    try testing.expectEqual([2]usize{ 3, 4 }, b[2]);
    try testing.expectEqual([2]usize{ 4, 5 }, b[3]);

    const none = try batches(gpa, &.{}, batch_count, batch_bytes);
    defer gpa.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "the request body is the reports as a JSON array; 200 and 413 count as sent" {
    const gpa = testing.allocator;
    const b = try body(gpa, &.{ "{\"a\":1}", "{\"b\":2}" });
    defer gpa.free(b);
    try testing.expectEqualStrings("[{\"a\":1},{\"b\":2}]", b);
    try testing.expect(markSentAfter(200));
    try testing.expect(markSentAfter(413));
    try testing.expect(!markSentAfter(401));
    try testing.expect(!markSentAfter(500));
}

test "sent.list keeps only reports still on the phone" {
    const gpa = testing.allocator;
    const text = try sentListText(gpa, &.{ "3-c.json", "1-a.json", "9-gone.json", "1-a.json" }, &.{ "1-a.json", "3-c.json", "4-d.json" });
    defer gpa.free(text);
    try testing.expectEqualStrings("1-a.json\n3-c.json", text);
    try testing.expect(isSent(text, "3-c.json"));
    try testing.expect(!isSent(text, "4-d.json"));
}

test "summary reads MetricKit's JSON as the Crash reports list shows it" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const crash = summary(arena,
        \\{"crashDiagnostics":[{"diagnosticMetaData":{"appBuildVersion":"42","exceptionType":1,"signal":11}}],"hangDiagnostics":[{}]}
    );
    try testing.expectEqual(@as(usize, 1), crash.crashes);
    try testing.expectEqual(@as(usize, 1), crash.hangs);
    try testing.expectEqualStrings("42", crash.build.?);
    try testing.expectEqualStrings("Crash: EXC_BAD_ACCESS · SIGSEGV", crash.headline);

    const watchdog = summary(arena,
        \\{"crashDiagnostics":[{"diagnosticMetaData":{"terminationReason":"Namespace RUNNINGBOARD, Code 0x8badf00d\nmore"}}]}
    );
    try testing.expectEqualStrings("Crash: Namespace RUNNINGBOARD, Code 0x8badf00d", watchdog.headline);
    const hang = summary(arena,
        \\{"hangDiagnostics":[{"diagnosticMetaData":{"hangDuration":"3.2 sec"}}]}
    );
    try testing.expectEqualStrings("Hang (3.2 sec)", hang.headline);
    try testing.expectEqualStrings("Too much CPU in the background", summary(arena, "{\"cpuExceptionDiagnostics\":[{}]}").headline);
    try testing.expectEqualStrings("Slow launch", summary(arena, "{\"appLaunchDiagnostics\":[{}]}").headline);
    try testing.expectEqualStrings("Diagnostics", summary(arena, "not json").headline);
    try testing.expectEqualStrings("Crash: signal 7", crashHeadline(arena, (try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"signal\":7}", .{})).object));
}

test "save keeps each report once; upload sends oldest first and stops at a failure" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
    defer gpa.free(base);
    const folder = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ base, folder_name });
    defer gpa.free(folder);

    save(gpa, testing.io, folder, &.{ "{\"r\":1}", "{\"r\":1}" }, 1000);
    save(gpa, testing.io, folder, &.{"{\"r\":2}"}, 2000);
    save(gpa, testing.io, folder, &.{"{\"r\":1}"}, 3000);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    try testing.expectEqual(@as(usize, 2), listReports(arena_state.allocator(), testing.io, folder).len);

    const Recorder = struct {
        bodies: std.ArrayList([]u8) = .empty,
        status: ?u16 = 200,
        fn send(self: *@This(), payload: []const u8) ?u16 {
            self.bodies.append(testing.allocator, testing.allocator.dupe(u8, payload) catch return null) catch return null;
            return self.status;
        }
        fn deinit(self: *@This()) void {
            for (self.bodies.items) |b| testing.allocator.free(b);
            self.bodies.deinit(testing.allocator);
        }
    };
    const Post = struct {
        r: *Recorder,
        pub fn send(p: @This(), payload: []const u8) ?u16 {
            return p.r.send(payload);
        }
    };

    var failing: Recorder = .{ .status = 503 };
    defer failing.deinit();
    upload(gpa, testing.io, folder, Post{ .r = &failing });
    try testing.expectEqualStrings("[{\"r\":1},{\"r\":2}]", failing.bodies.items[0]);

    var ok: Recorder = .{};
    defer ok.deinit();
    upload(gpa, testing.io, folder, Post{ .r = &ok });
    try testing.expectEqual(@as(usize, 1), ok.bodies.items.len);
    // Sent once: the next run has nothing to send.
    var again: Recorder = .{};
    defer again.deinit();
    upload(gpa, testing.io, folder, Post{ .r = &again });
    try testing.expectEqual(@as(usize, 0), again.bodies.items.len);
}
