//! Device and preview RPCs through `EngineHost.handle`: the handler bodies
//! reach their modules and answer in the Rust engine's shapes. No process is
//! spawned here (the host has no `Io`, so commands fail to start).
const std = @import("std");
const testing = std.testing;
const json = std.json;
const engine_host = @import("engine_host.zig");

fn call(host: *engine_host.EngineHost, method: []const u8, params_text: []const u8) !engine_host.RpcOutcome {
    const parsed = try json.parseFromSlice(json.Value, testing.allocator, params_text, .{});
    defer parsed.deinit();
    return host.handle(method, parsed.value);
}

fn freeOutcome(o: *engine_host.RpcOutcome) void {
    switch (o.*) {
        .unary_json => |b| testing.allocator.free(b),
        .stream_items_json => |*s| s.deinit(testing.allocator),
        .err => {},
    }
}

test "rpc devices: simulator methods answer through the engine host" {
    var host = try engine_host.EngineHost.init(testing.allocator, "dev-test", "Test Mac");
    defer host.deinit();

    var list = try call(&host, "ListSimulators", "{}");
    defer freeOutcome(&list);
    if (@import("builtin").os.tag == .macos) {
        try testing.expectEqualStrings(
            "{\"supported\":false,\"reason\":\"Xcode wasn't found on this computer.\",\"setUp\":false,\"devices\":[]}",
            list.unary_json,
        );
    } else {
        try testing.expectEqualStrings(
            "{\"supported\":false,\"reason\":\"iOS Simulators need a Mac with Xcode.\",\"setUp\":false,\"devices\":[]}",
            list.unary_json,
        );
    }

    var missing = try call(&host, "BootSimulator", "{}");
    defer freeOutcome(&missing);
    try testing.expectEqualStrings("missing field `simulatorId`", missing.err.bad_params);

    var bad = try call(&host, "ShutdownSimulator", "{\"simulatorId\":\"booted\"}");
    defer freeOutcome(&bad);
    if (@import("builtin").os.tag == .macos) {
        try testing.expectEqualStrings("not a simulator id: \"booted\"", bad.err.exec_error);
    }
}

test "rpc devices: sandbox methods answer through the engine host" {
    var host = try engine_host.EngineHost.init(testing.allocator, "dev-test", "Test Mac");
    defer host.deinit();

    var missing = try call(&host, "CodegraffSandboxAction", "{\"action\":\"stop\"}");
    defer freeOutcome(&missing);
    try testing.expectEqualStrings("missing sandbox id", missing.err.exec_error);

    var unknown = try call(&host, "CodegraffSandboxAction", "{\"id\":\"cnd_1\",\"action\":\"explode\"}");
    defer freeOutcome(&unknown);
    try testing.expectEqualStrings("unknown sandbox action", unknown.err.exec_error);

    if (@import("proc_seam.zig").getenv("CODEGRAFF_API_KEY") == null) {
        // Signed out: `Option<CodegraffSandboxes>` is null, and nothing is called.
        var list = try call(&host, "CodegraffSandboxes", "{}");
        defer freeOutcome(&list);
        try testing.expectEqualStrings("null", list.unary_json);
        var create = try call(&host, "CodegraffCreateTemporarySandbox", "{}");
        defer freeOutcome(&create);
        try testing.expectEqualStrings("Sign in with Codegraff first.", create.err.exec_error);
    }
}

test "rpc devices: update methods answer through the engine host" {
    var host = try engine_host.EngineHost.init(testing.allocator, "dev-test", "Test Mac");
    defer host.deinit();
    const version = @import("build_info").version;

    var status = try call(&host, "UpdateStatus", "{\"targetDeviceId\":\"dev-test\"}");
    defer freeOutcome(&status);
    const want = "{\"currentVersion\":\"" ++ version ++ "\",\"updateAvailable\":false,\"host\":{\"mode\":\"manual\",\"automatic\":";
    try testing.expect(std.mem.startsWith(u8, status.stream_items_json.items[0], want));

    var elsewhere = try call(&host, "CheckForUpdates", "{\"targetDeviceId\":\"another-device\"}");
    defer freeOutcome(&elsewhere);
    try testing.expectEqualStrings("target device not connected", elsewhere.err.exec_error);

    var check = try call(&host, "CheckForUpdates", "{}");
    defer freeOutcome(&check);
    try testing.expectEqualStrings("{\"ok\":true}", check.unary_json);

    // The test binary is not a managed install: both refuse, with the Rust engine's words.
    var queue = try call(&host, "QueueUpdate", "{}");
    defer freeOutcome(&queue);
    try testing.expectEqualStrings("this device cannot queue a remote update; update its desktop app or package locally", queue.err.exec_error);
    var apply = try call(&host, "ApplyUpdate", "{}");
    defer freeOutcome(&apply);
    try testing.expectEqualStrings("this install is not update-managed — the desktop app updates from its UI; source builds update via git", apply.err.exec_error);
}
