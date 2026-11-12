//! Stopping a test's loopback server whose thread blocks in `accept`: set
//! its stop flag first, then wake the accept with a connection, again until
//! the loop has signalled `exited`, and join. One wake-up can be lost; a
//! join that never returns would hang the whole suite, so past 5 s this
//! fails instead of waiting.
const std = @import("std");
const Io = std.Io;

pub fn stopAcceptLoop(io: Io, port: u16, exited: *Io.Event, thread: std.Thread) void {
    var tries: u32 = 0;
    while (!exited.isSet()) : (tries += 1) {
        if (tries >= 50) @panic("a test server did not stop within 5 s");
        if (Io.net.IpAddress.parseIp4("127.0.0.1", port)) |addr| {
            if (addr.connect(io, .{ .mode = .stream })) |c| c.close(io) else |_| {}
        } else |_| {}
        exited.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(100), .clock = .awake } }) catch {};
    }
    thread.join();
}
