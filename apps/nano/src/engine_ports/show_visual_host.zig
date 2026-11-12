//! `ShowVisual {chatId, id, title, script}`: validate a native visual and
//! publish it into the chat's live run (`crates/engine/src/rpc.rs`,
//! `SessionManager::show_visual` and the run's visual intake).
//!
//! Local chats only; the id, title and script bounds; a live run; a reused
//! id must carry the same title and script; setup and the first render must
//! pass the sandbox (`visual_sandbox.zig`). The visual becomes a `visual`
//! part (`MessagePart::Visual {id, title, script}`) on the run's message.
const std = @import("std");
const json = std.json;
const engine_host = @import("../engine_host.zig");
const media = @import("show_media_host.zig");
const sandbox = @import("visual_sandbox.zig");

const EngineHost = engine_host.EngineHost;
const RpcOutcome = engine_host.RpcOutcome;

pub const check_failed = "show_visual script failed bounded first-render validation";

fn failed(msg: []const u8) RpcOutcome {
    return .{ .err = .{ .exec_error = msg } };
}

pub fn showVisual(host: *EngineHost, params: json.Value) !RpcOutcome {
    if (params != .object) return .{ .err = .{ .bad_params = "expected object" } };
    const obj = params.object;
    if (media.checkFields(obj, &.{ "chatId", "id", "title", "script" }, &.{})) |m| return .{ .err = .{ .bad_params = m } };
    const chat_id = obj.get("chatId").?.string;
    const req_id = obj.get("id").?.string;
    const title = obj.get("title").?.string;
    const script = obj.get("script").?.string;

    switch (media.localChat(host, chat_id)) {
        .ok => {},
        .err => |e| return e,
    }
    if (!media.validRequestId(req_id)) return failed("show_visual id is invalid");
    if (sandbox.validateVisual(title, script)) |m| return failed(m);
    const doc = try host.getOrCreateDoc(chat_id);
    const run_msg = media.activeRunMessage(doc) orelse return failed("No active run accepts visuals for this chat");

    const part_id = try std.fmt.allocPrint(host.gpa, "show-visual:{s}", .{req_id});
    defer host.gpa.free(part_id);
    if (media.findPart(doc, run_msg, part_id)) |existing| {
        const cj = existing.call_json orelse return failed("show_visual id already used with different parameters");
        const parsed = json.parseFromSlice(json.Value, host.gpa, cj, .{}) catch return failed("show_visual id already used with different parameters");
        defer parsed.deinit();
        const same = std.mem.eql(u8, existing.kind, "visual") and parsed.value == .object and
            eqlStr(parsed.value.object.get("title"), title) and eqlStr(parsed.value.object.get("script"), script);
        if (!same) return failed("show_visual id already used with different parameters");
        return reply(host, part_id, title);
    }

    const io = host.io orelse return failed("visual validation worker failed");
    // Luau (C++) does not build for iOS with Zig's libc++: the phone's
    // in-process engine has no visual sandbox (build.zig leaves Luau out).
    if (comptime @import("builtin").os.tag == .ios) return failed("Visual scripts are not supported on this device");
    var err_buf: [256]u8 = undefined;
    if (sandbox.check(host.gpa, io, script, &err_buf) != null) return failed(check_failed);

    const fields = try std.fmt.allocPrint(host.gpa, "{{\"title\":{f},\"script\":{f}}}", .{ json.fmt(title, .{}), json.fmt(script, .{}) });
    defer host.gpa.free(fields);
    media.attachPart(host, chat_id, doc, run_msg, part_id, "visual", fields) catch
        return failed("show_visual could not sync the visual into the chat");
    return reply(host, part_id, title);
}

fn eqlStr(v: ?json.Value, s: []const u8) bool {
    const x = v orelse return false;
    return x == .string and std.mem.eql(u8, x.string, s);
}

fn reply(host: *EngineHost, part_id: []const u8, title: []const u8) !RpcOutcome {
    return .{ .unary_json = try std.fmt.allocPrint(host.gpa, "{{\"attached\":true,\"id\":{f},\"title\":{f}}}", .{
        json.fmt(part_id, .{}), json.fmt(title, .{}),
    }) };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const good = "{\"chatId\":\"chat-1\",\"id\":\"cap-1\",\"title\":\"Capacity\",\"script\":\"local n = 2 return function() return ui.column{ ui.text('Synthetic'), ui.chart{values={n, n * 2}} } end\"}";

test "ShowVisual validates the script and attaches it to the live run" {
    var t: media.TestChat = undefined;
    try t.init();
    defer t.deinit();
    try t.expectErr("ShowVisual", good, "No active run accepts visuals for this chat");
    try t.startRun();
    const r = try t.handle("ShowVisual", good);
    defer testing.allocator.free(r.unary_json);
    try testing.expectEqualStrings("{\"attached\":true,\"id\":\"show-visual:cap-1\",\"title\":\"Capacity\"}", r.unary_json);
    const frame = try t.resetFrame();
    defer testing.allocator.free(frame);
    try testing.expect(std.mem.indexOf(u8, frame, "{\"id\":\"show-visual:cap-1\",\"kind\":\"visual\",\"title\":\"Capacity\",\"script\":\"local n = 2 return function()") != null);

    // The same id again: fine with the same parameters, refused with others.
    const again = try t.handle("ShowVisual", good);
    defer testing.allocator.free(again.unary_json);
    try t.expectErr("ShowVisual", "{\"chatId\":\"chat-1\",\"id\":\"cap-1\",\"title\":\"Other\",\"script\":\"return function() return ui.rule{} end\"}", "show_visual id already used with different parameters");

    // A snapshot keeps it.
    const doc = try t.host.getOrCreateDoc("chat-1");
    const snap = try doc.exportSnapshot(testing.allocator);
    defer testing.allocator.free(snap);
    var copy = try @import("../session_doc.zig").SessionDoc.init(testing.allocator, "chat-1", "dev-a");
    defer copy.deinit();
    try copy.importSnapshot(snap);
    const frame2 = try copy.toResetFrameJson(testing.allocator);
    defer testing.allocator.free(frame2);
    try testing.expectEqualStrings(frame, frame2);
}

test "ShowVisual returns Rust's errors for bad params and invalid scripts" {
    var t: media.TestChat = undefined;
    try t.init();
    defer t.deinit();
    try t.startRun();
    try t.expectErr("ShowVisual", "{\"chatId\":\"chat-1\",\"id\":\"v\",\"title\":\"T\"}", "missing field `script`");
    try t.expectErr("ShowVisual", "{\"chatId\":\"chat-1\",\"id\":\"v\",\"title\":\"T\",\"script\":\"x\",\"style\":1}", "unknown field");
    try t.expectErr("ShowVisual", "{\"chatId\":\"nope\",\"id\":\"v\",\"title\":\"T\",\"script\":\"x\"}", "chat not found");
    try t.expectErr("ShowVisual", "{\"chatId\":\"chat-1\",\"id\":\"v v\",\"title\":\"T\",\"script\":\"x\"}", "show_visual id is invalid");
    try t.expectErr("ShowVisual", "{\"chatId\":\"chat-1\",\"id\":\"v\",\"title\":\"  \",\"script\":\"x\"}", "visual title must be nonblank and at most 200 characters");
    try t.expectErr("ShowVisual", "{\"chatId\":\"chat-1\",\"id\":\"v\",\"title\":\"T\",\"script\":\" \"}", "visual script must be nonblank and at most 64 KiB of UTF-8");
    for ([_][]const u8{
        "while true do end",
        "return function() return ui.text{text='a', color='red'} end",
        "local c = {} for i = 1, 600 do c[i] = ui.rule{} end return function() return ui.column(c) end",
        "os.exit()",
    }) |script| {
        const req = try std.fmt.allocPrint(t.arena.allocator(), "{{\"chatId\":\"chat-1\",\"id\":\"v\",\"title\":\"T\",\"script\":{f}}}", .{json.fmt(script, .{})});
        try t.expectErr("ShowVisual", req, check_failed);
    }
    // Nothing was attached.
    const frame = try t.resetFrame();
    defer testing.allocator.free(frame);
    try testing.expect(std.mem.indexOf(u8, frame, "show-visual:") == null);
}
