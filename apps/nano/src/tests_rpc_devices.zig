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
