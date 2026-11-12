//! Project-owned C ABI over retained harness-doc + Loro (not upstream UniFFI).
//! Explicit static mode: -Dloro-lib. Sideloaded macOS mode: -Dloro-dylib.
//! A Doc owns a loader reference until its Rust handle/buffers are freed.
//! Calls on each document must be serialized by its owner.
const std = @import("std");
const options = @import("sync_options");
pub const enabled = options.loro_enabled;
pub const dynamic = options.loro_dynamic;
const Buffer = extern struct { ptr: ?[*]u8, len: usize };
extern fn harness_loro_abi_version() u32;
extern fn harness_loro_capabilities() u64;
extern fn harness_loro_new([*]const u8, usize, *?*anyopaque, *Buffer) c_int;
extern fn harness_loro_call(*anyopaque, u32, ?[*]const u8, usize, *Buffer) c_int;
extern fn harness_loro_free(*anyopaque) void;
extern fn harness_loro_buffer_free(Buffer) void;
extern "c" fn getenv([*:0]const u8) ?[*:0]const u8;
extern "c" fn _NSGetExecutablePath([*]u8, *u32) c_int;
extern "c" fn realpath([*:0]const u8, [*]u8) ?[*:0]u8;

const Api = struct {
    lib: ?std.DynLib = null,
    new: @TypeOf(&harness_loro_new),
    call: @TypeOf(&harness_loro_call),
    free: @TypeOf(&harness_loro_free),
    buffer_free: @TypeOf(&harness_loro_buffer_free),

    fn symbol(lib: *std.DynLib, comptime T: type, comptime name: [:0]const u8) !T {
        return lib.lookup(T, name) orelse error.LoroSymbolMissing;
    }
    fn open() !Api {
        if (!enabled) return error.LoroNotLinked;
        if (!dynamic) {
            if (harness_loro_abi_version() != 1) return error.LoroAbiMismatch;
            if (harness_loro_capabilities() & 0x3f != 0x3f) return error.LoroCapabilitiesMissing;
            return .{ .new = &harness_loro_new, .call = &harness_loro_call, .free = &harness_loro_free, .buffer_free = &harness_loro_buffer_free };
        }
        // dyld can redirect even absolute dlopen paths. Do not participate in
        // ambient library substitution. This is not a sandbox against code
        // injected before main (e.g. DYLD_INSERT_LIBRARIES).
        inline for (.{ "DYLD_LIBRARY_PATH", "DYLD_FALLBACK_LIBRARY_PATH", "DYLD_VERSIONED_LIBRARY_PATH", "DYLD_ROOT_PATH", "DYLD_IMAGE_SUFFIX", "DYLD_FRAMEWORK_PATH", "DYLD_FALLBACK_FRAMEWORK_PATH", "DYLD_VERSIONED_FRAMEWORK_PATH", "DYLD_INSERT_LIBRARIES" }) |key| {
            if (getenv(key)) |value| if (value[0] != 0) return error.LoroAmbientLoaderOverride;
        }
        // No cwd, PATH, DYLD_* or bare-name search. Explicit overrides are
        // trusted executable code, must be absolute, and NEVER fall back.
        var path: [4096]u8 = undefined;
        const selected: [:0]const u8 = if (getenv("HARNESS_NANO_LORO_LIBRARY")) |p|
            std.mem.span(p)
        else blk: {
            var exe: [4096]u8 = undefined;
            var size: u32 = exe.len;
            if (_NSGetExecutablePath(&exe, &size) != 0) return error.LoroExecutablePath;
            var canonical: [4096]u8 = undefined;
            const resolved = realpath(@ptrCast(&exe), &canonical) orelse return error.LoroExecutablePath;
            const dir = std.fs.path.dirname(std.mem.span(resolved)) orelse return error.LoroExecutablePath;
            const formatted = try std.fmt.bufPrint(&path, "{s}/libharness_nano_loro.dylib\x00", .{dir});
            break :blk path[0 .. formatted.len - 1 :0];
        };
        if (!std.fs.path.isAbsolute(selected)) return error.LoroLibraryPathNotAbsolute;
        // Resolve every relocation now rather than discovering an unavailable
        // dependency while a document already owns state.
        var canonical_library: [4096]u8 = undefined;
        const resolved_library = realpath(selected.ptr, &canonical_library) orelse return error.LoroLibraryMissing;
        const handle = std.c.dlopen(resolved_library, .{ .NOW = true }) orelse {
            const raw = std.c.dlerror();
            const why = if (raw) |p| std.mem.span(p) else "";
            if (std.mem.indexOf(u8, why, "incompatible architecture") != null or std.mem.indexOf(u8, why, "wrong architecture") != null) return error.LoroArchitectureMismatch;
            if (std.mem.indexOf(u8, why, "code signature") != null) return error.LoroSignatureRejected;
            if (std.mem.indexOf(u8, why, "not a mach-o") != null or std.mem.indexOf(u8, why, "not a Mach-O") != null or std.mem.indexOf(u8, why, "not valid mach-o") != null) return error.LoroInvalidLibrary;
            if (std.mem.indexOf(u8, why, "no such file") != null) return error.LoroLibraryMissing;
            return error.LoroLibraryLoadFailed;
        };
        var lib: std.DynLib = .{ .inner = .{ .handle = handle } };
        errdefer lib.close();
        const version = try symbol(&lib, @TypeOf(&harness_loro_abi_version), "harness_loro_abi_version");
        const capabilities = try symbol(&lib, @TypeOf(&harness_loro_capabilities), "harness_loro_capabilities");
        if (version() != 1) return error.LoroAbiMismatch;
        if (capabilities() & 0x3f != 0x3f) return error.LoroCapabilitiesMissing;
        return .{
            .lib = lib,
            .new = try symbol(&lib, @TypeOf(&harness_loro_new), "harness_loro_new"),
            .call = try symbol(&lib, @TypeOf(&harness_loro_call), "harness_loro_call"),
            .free = try symbol(&lib, @TypeOf(&harness_loro_free), "harness_loro_free"),
            .buffer_free = try symbol(&lib, @TypeOf(&harness_loro_buffer_free), "harness_loro_buffer_free"),
        };
    }
    fn close(self: *Api) void {
        if (self.lib) |*lib| lib.close();
        self.lib = null;
    }
};

/// Startup preflight, before profiles or sockets are opened. Legacy mode is
/// deliberately unaffected; requested Loro mode never silently becomes HZD1.
pub fn validate() !void {
    if (!enabled) return;
    var api = try Api.open();
    defer api.close();
}

pub const Doc = struct {
    handle: *anyopaque,
    api: Api,

    pub fn init(chat: []const u8) !Doc {
        var api = try Api.open();
        errdefer api.close();
        var h: ?*anyopaque = null;
        var buf: Buffer = .{ .ptr = null, .len = 0 };
        const status = api.new(chat.ptr, chat.len, &h, &buf);
        defer api.buffer_free(buf);
        if (status < 0 or h == null) return error.LoroCreateFailed;
        return .{ .handle = h.?, .api = api };
    }
    pub fn deinit(self: Doc) void {
        if (!enabled) return;
        self.api.free(self.handle);
        var api = self.api;
        api.close();
    }
    fn call(self: Doc, gpa: std.mem.Allocator, op: u32, input: []const u8) !struct { bytes: []u8, pending: bool } {
        if (!enabled) return error.LoroNotLinked;
        var buf: Buffer = .{ .ptr = null, .len = 0 };
        const status = self.api.call(self.handle, op, input.ptr, input.len, &buf);
        defer self.api.buffer_free(buf);
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

test "retained Loro: closing one dylib reference preserves another document" {
    if (!enabled) return;
    const first = try Doc.init("synthetic-first");
    const second = try Doc.init("synthetic-second");
    defer second.deinit();
    first.deinit();
    const snapshot = try second.bytes(std.testing.allocator, 3, "");
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(snapshot.len > 0);
}
