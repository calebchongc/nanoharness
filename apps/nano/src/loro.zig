//! Project-owned native wrapper over harness-nano-loro's C ABI, NOT an
//! official loro-ffi Zig binding. Enabled explicitly with -Dloro-lib.
//! Calls are serialized by the document/engine owner. Rust owns its handle
//! and return buffers; copy to the Zig allocator, then free in Rust.
const std = @import("std");
pub const enabled = @import("sync_options").loro_enabled;
const Buffer = extern struct { ptr: ?[*]u8, len: usize };
extern fn harness_loro_new([*]const u8, usize, *?*anyopaque, *Buffer) c_int;
extern fn harness_loro_call(*anyopaque, u32, ?[*]const u8, usize, *Buffer) c_int;
extern fn harness_loro_free(*anyopaque) void;
extern fn harness_loro_buffer_free(Buffer) void;

pub const Doc = struct {
    handle: *anyopaque,

    pub fn init(chat: []const u8) !Doc {
        if (!enabled) return error.LoroNotLinked;
        var h: ?*anyopaque = null;
        var buf: Buffer = .{ .ptr = null, .len = 0 };
        const status = harness_loro_new(chat.ptr, chat.len, &h, &buf);
        defer harness_loro_buffer_free(buf);
        if (status < 0 or h == null) return error.LoroCreateFailed;
        return .{ .handle = h.? };
    }
    pub fn deinit(self: Doc) void {
        if (enabled) harness_loro_free(self.handle);
    }
    fn call(self: Doc, gpa: std.mem.Allocator, op: u32, input: []const u8) !struct { bytes: []u8, pending: bool } {
        if (!enabled) return error.LoroNotLinked;
        var buf: Buffer = .{ .ptr = null, .len = 0 };
        const status = harness_loro_call(self.handle, op, input.ptr, input.len, &buf);
        defer harness_loro_buffer_free(buf);
        if (status < 0) {
            if (buf.ptr) |p| std.log.warn("retained Loro: {s}", .{p[0..buf.len]});
            return error.LoroOperationFailed;
        }
        return .{ .bytes = try gpa.dupe(u8, if (buf.ptr) |p| p[0..buf.len] else ""), .pending = status == 1 };
    }
    pub fn bytes(self: Doc, gpa: std.mem.Allocator, op: u32, input: []const u8) ![]u8 {
        return (try self.call(gpa, op, input)).bytes;
    }
    pub fn command(self: Doc, gpa: std.mem.Allocator, op: u32, input: []const u8) !bool {
        const r = try self.call(gpa, op, input);
        defer gpa.free(r.bytes);
        return r.pending;
    }
};
