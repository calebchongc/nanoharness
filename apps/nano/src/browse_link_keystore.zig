//! Where Harness keeps its browse pairing key, ported from
//! `crates/engine/src/browse_link/keystore.rs`. On macOS it is a login
//! Keychain item (generic password, service "Harness browse pairing", account
//! `client-key:<first 8 bytes of sha256(data dir), hex>`), whose access list
//! trusts the app that created it. Elsewhere it is a 0600 file
//! (`<data dir>/browse-link.key`); browse itself is macOS-only.
//!
//! The Security framework is loaded at run time (`std.DynLib`), so the build
//! doesn't link it. Every store sits behind `KeyStore` (a vtable), and
//! `override` replaces the platform store, so tests use `MemoryKeyStore` and
//! never touch the real Keychain.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const wire = @import("browse_link_wire.zig");

pub const SERVICE = "Harness browse pairing";
pub const KEY_FILE = "browse-link.key";

/// A store for the 32-byte P-256 secret.
pub const KeyStore = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    /// `deinit` frees the store (false for a borrowed one, like `override`).
    owned: bool = true,

    pub const VTable = struct {
        /// The stored bytes (owned by `gpa`), or null when there are none or
        /// they can't be read (Rust's `.ok()?`).
        read: *const fn (ptr: *anyopaque, gpa: Allocator, io: Io) ?[]u8,
        /// Store `bytes`; on failure, the whole error text Rust shows
        /// (owned by `gpa`).
        write: *const fn (ptr: *anyopaque, gpa: Allocator, io: Io, bytes: []const u8) ?[]u8,
        /// Forget the key; failures are ignored, as in Rust.
        delete: *const fn (ptr: *anyopaque, io: Io) void,
        /// Free the store itself (stores built by `forDataDir`).
        deinit: *const fn (ptr: *anyopaque, gpa: Allocator) void,
    };

    pub fn load(self: KeyStore, gpa: Allocator, io: Io) ?wire.KeyPair {
        const bytes = self.vtable.read(self.ptr, gpa, io) orelse return null;
        defer {
            std.crypto.secureZero(u8, bytes);
            gpa.free(bytes);
        }
        return wire.keyFromBytes(bytes);
    }

    pub const Created = union(enum) {
        key: wire.KeyPair,
        /// The error text (owned).
        failed: []u8,
    };

    /// `load_or_create`: the stored key, else a new one, saved first.
    pub fn loadOrCreate(self: KeyStore, gpa: Allocator, io: Io) Created {
        if (self.load(gpa, io)) |key| return .{ .key = key };
        const key = wire.newKey(io);
        var bytes = key.secret_key.toBytes();
        defer std.crypto.secureZero(u8, &bytes);
        if (self.vtable.write(self.ptr, gpa, io, &bytes)) |message| return .{ .failed = message };
        return .{ .key = key };
    }

    pub fn delete(self: KeyStore, io: Io) void {
        self.vtable.delete(self.ptr, io);
    }

    pub fn deinit(self: KeyStore, gpa: Allocator) void {
        if (self.owned) self.vtable.deinit(self.ptr, gpa);
    }
};

/// Replaces the platform store for every new link (the engine's own tests,
/// for example). Not owned: `deinit` on it is left to whoever set it.
pub var override: ?KeyStore = null;

/// The platform store for `data_dir`. Each data directory (the release app,
/// a dev build) gets its own key and pairing.
pub fn forDataDir(gpa: Allocator, data_dir: []const u8) !KeyStore {
    if (override) |store| {
        var b = store;
        b.owned = false;
        return b;
    }
    if (comptime builtin.os.tag == .macos) {
        const store = try gpa.create(Keychain);
        errdefer gpa.destroy(store);
        store.* = .{ .account = try keychainAccount(gpa, data_dir) };
        return store.keyStore();
    }
    const store = try gpa.create(FileStore);
    errdefer gpa.destroy(store);
    store.* = .{ .path = try std.fs.path.join(gpa, &.{ data_dir, KEY_FILE }) };
    return store.keyStore();
}

/// `client-key:` and the first 8 bytes of SHA-256(data dir), hex.
pub fn keychainAccount(gpa: Allocator, data_dir: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data_dir, &digest, .{});
    var hex: [16]u8 = undefined;
    return std.fmt.allocPrint(gpa, "client-key:{s}", .{wire.hexInto(&hex, digest[0..8])});
}

// ── files (non-macOS) ─────────────────────────────────────────────────────

pub const FileStore = struct {
    path: []u8,

    pub fn keyStore(self: *FileStore) KeyStore {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: KeyStore.VTable = .{ .read = read, .write = write, .delete = delete, .deinit = deinitFn };

    fn read(ptr: *anyopaque, gpa: Allocator, io: Io) ?[]u8 {
        const self: *FileStore = @ptrCast(@alignCast(ptr));
        return Io.Dir.cwd().readFileAlloc(io, self.path, gpa, .limited(1 << 16)) catch null;
    }

    fn write(ptr: *anyopaque, gpa: Allocator, io: Io, bytes: []const u8) ?[]u8 {
        const self: *FileStore = @ptrCast(@alignCast(ptr));
        writePrivate(gpa, io, self.path, bytes) catch |e| {
            return std.fmt.allocPrint(gpa, "couldn't save the pairing key: {s}", .{ioErrorText(e)}) catch null;
        };
        return null;
    }

    fn delete(ptr: *anyopaque, io: Io) void {
        const self: *FileStore = @ptrCast(@alignCast(ptr));
        Io.Dir.cwd().deleteFile(io, self.path) catch {};
    }

    fn deinitFn(ptr: *anyopaque, gpa: Allocator) void {
        const self: *FileStore = @ptrCast(@alignCast(ptr));
        gpa.free(self.path);
        gpa.destroy(self);
    }
};

/// `std::io::Error`'s text for the errors a private write can hit.
pub fn ioErrorText(e: anyerror) []const u8 {
    return switch (e) {
        error.AccessDenied, error.PermissionDenied => "Permission denied (os error 13)",
        error.FileNotFound => "No such file or directory (os error 2)",
        error.NotDir => "Not a directory (os error 20)",
        error.IsDir => "Is a directory (os error 21)",
        error.NoSpaceLeft => "No space left on device (os error 28)",
        error.ReadOnlyFileSystem => "Read-only file system (os error 30)",
        error.PathAlreadyExists => "File exists (os error 17)",
        else => @errorName(e),
    };
}

const private_permissions: Io.File.Permissions = if (builtin.os.tag == .windows)
    .default_file
else
    .fromMode(0o600);

/// `write_private`: create the parent directories, write a 0600 sibling
/// (`<stem>.tmp-<uuid>`), sync it, and rename it over `path`.
pub fn writePrivate(gpa: Allocator, io: Io, path: []const u8, bytes: []const u8) !void {
    const cwd = Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |dir| if (dir.len > 0) try cwd.createDirPath(io, dir);
    const staged = try stagedPath(gpa, io, path);
    defer gpa.free(staged);
    {
        const file = try cwd.createFile(io, staged, .{ .exclusive = true, .permissions = private_permissions });
        defer file.close(io);
        errdefer cwd.deleteFile(io, staged) catch {};
        try file.writeStreamingAll(io, bytes);
        try file.sync(io);
    }
    cwd.rename(staged, cwd, path, io) catch |e| {
        cwd.deleteFile(io, staged) catch {};
        return e;
    };
}

/// `path.with_extension(format!("tmp-{uuid}"))`.
fn stagedPath(gpa: Allocator, io: Io, path: []const u8) ![]u8 {
    var raw: [16]u8 = undefined;
    io.random(&raw);
    raw[6] = (raw[6] & 0x0f) | 0x40;
    raw[8] = (raw[8] & 0x3f) | 0x80;
    var hex: [32]u8 = undefined;
    _ = wire.hexInto(&hex, &raw);
    const ext = std.fs.path.extension(path);
    const base = path[0 .. path.len - ext.len];
    return std.fmt.allocPrint(gpa, "{s}.tmp-{s}-{s}-{s}-{s}-{s}", .{ base, hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32] });
}

// ── an in-memory store (tests) ────────────────────────────────────────────

/// A store kept in memory, for tests: no file, no Keychain. Failures can be
/// injected.
pub const MemoryKeyStore = struct {
    mutex: Io.Mutex = .init,
    bytes: ?[32]u8 = null,
    /// When set, saving fails with this text (as the platform store's own
    /// error would read).
    fail_write: ?[]const u8 = null,
    /// When set, reading finds nothing (a locked or denied Keychain).
    fail_read: bool = false,
    writes: usize = 0,
    deletes: usize = 0,

    pub fn keyStore(self: *MemoryKeyStore) KeyStore {
        return .{ .ptr = self, .vtable = &vtable, .owned = false };
    }

    const vtable: KeyStore.VTable = .{ .read = read, .write = write, .delete = delete, .deinit = noDeinit };

    fn noDeinit(_: *anyopaque, _: Allocator) void {}

    fn read(ptr: *anyopaque, gpa: Allocator, io: Io) ?[]u8 {
        const self: *MemoryKeyStore = @ptrCast(@alignCast(ptr));
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.fail_read) return null;
        const b = self.bytes orelse return null;
        return gpa.dupe(u8, &b) catch null;
    }

    fn write(ptr: *anyopaque, gpa: Allocator, io: Io, bytes: []const u8) ?[]u8 {
        const self: *MemoryKeyStore = @ptrCast(@alignCast(ptr));
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.fail_write) |message| return gpa.dupe(u8, message) catch null;
        if (bytes.len != 32) return gpa.dupe(u8, "couldn't save the pairing key: bad length") catch null;
        self.bytes = bytes[0..32].*;
        self.writes += 1;
        return null;
    }

    fn delete(ptr: *anyopaque, io: Io) void {
        const self: *MemoryKeyStore = @ptrCast(@alignCast(ptr));
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.bytes = null;
        self.deletes += 1;
    }

    pub fn has(self: *MemoryKeyStore, io: Io) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.bytes != null;
    }
};

// ── the macOS Keychain ─────────────────────────────────────────────────────

pub const Keychain = struct {
    account: []u8,

    pub fn keyStore(self: *Keychain) KeyStore {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: KeyStore.VTable = .{ .read = read, .write = write, .delete = delete, .deinit = deinitFn };

    fn read(ptr: *anyopaque, gpa: Allocator, io: Io) ?[]u8 {
        if (comptime builtin.os.tag != .macos) return null;
        const self: *Keychain = @ptrCast(@alignCast(ptr));
        const sec = security(io) orelse return null;
        return sec.getGenericPassword(gpa, SERVICE, self.account) catch null;
    }

    fn write(ptr: *anyopaque, gpa: Allocator, io: Io, bytes: []const u8) ?[]u8 {
        if (comptime builtin.os.tag != .macos) return gpa.dupe(u8, "couldn't save the pairing key in the Keychain: no Keychain on this platform") catch null;
        const self: *Keychain = @ptrCast(@alignCast(ptr));
        const sec = security(io) orelse
            return gpa.dupe(u8, "couldn't save the pairing key in the Keychain: the Security framework didn't load") catch null;
        const status = sec.setGenericPassword(SERVICE, self.account, bytes);
        if (status == 0) return null;
        var buf: [512]u8 = undefined;
        return std.fmt.allocPrint(gpa, "couldn't save the pairing key in the Keychain: {s}", .{sec.errorText(status, &buf)}) catch null;
    }

    fn delete(ptr: *anyopaque, io: Io) void {
        if (comptime builtin.os.tag != .macos) return;
        const self: *Keychain = @ptrCast(@alignCast(ptr));
        const sec = security(io) orelse return;
        _ = sec.deleteGenericPassword(SERVICE, self.account);
    }

    fn deinitFn(ptr: *anyopaque, gpa: Allocator) void {
        const self: *Keychain = @ptrCast(@alignCast(ptr));
        gpa.free(self.account);
        gpa.destroy(self);
    }
};

const CFTypeRef = ?*const anyopaque;
const CFIndex = isize;
const OSStatus = i32;
const kCFStringEncodingUTF8: u32 = 0x08000100;
const errSecDuplicateItem: OSStatus = -25299;

/// The Security and CoreFoundation calls `security-framework`'s
/// `passwords::{set,get,delete}_generic_password` make.
const Security = struct {
    CFStringCreateWithBytes: *const fn (CFTypeRef, [*]const u8, CFIndex, u32, u8) callconv(.c) CFTypeRef,
    CFDataCreate: *const fn (CFTypeRef, [*]const u8, CFIndex) callconv(.c) CFTypeRef,
    CFDictionaryCreate: *const fn (CFTypeRef, [*]const CFTypeRef, [*]const CFTypeRef, CFIndex, ?*const anyopaque, ?*const anyopaque) callconv(.c) CFTypeRef,
    CFRelease: *const fn (CFTypeRef) callconv(.c) void,
    CFGetTypeID: *const fn (CFTypeRef) callconv(.c) usize,
    CFDataGetTypeID: *const fn () callconv(.c) usize,
    CFDataGetLength: *const fn (CFTypeRef) callconv(.c) CFIndex,
    CFDataGetBytePtr: *const fn (CFTypeRef) callconv(.c) ?[*]const u8,
    CFStringGetCString: *const fn (CFTypeRef, [*]u8, CFIndex, u32) callconv(.c) u8,
    SecItemAdd: *const fn (CFTypeRef, ?*CFTypeRef) callconv(.c) OSStatus,
    SecItemUpdate: *const fn (CFTypeRef, CFTypeRef) callconv(.c) OSStatus,
    SecItemCopyMatching: *const fn (CFTypeRef, ?*CFTypeRef) callconv(.c) OSStatus,
    SecItemDelete: *const fn (CFTypeRef) callconv(.c) OSStatus,
    SecCopyErrorMessageString: *const fn (OSStatus, ?*anyopaque) callconv(.c) CFTypeRef,
    kSecClass: CFTypeRef,
    kSecClassGenericPassword: CFTypeRef,
    kSecAttrService: CFTypeRef,
    kSecAttrAccount: CFTypeRef,
    kSecValueData: CFTypeRef,
    kSecReturnData: CFTypeRef,
    kCFBooleanTrue: CFTypeRef,
    key_callbacks: *const anyopaque,
    value_callbacks: *const anyopaque,

    fn string(self: *const Security, text: []const u8) CFTypeRef {
        return self.CFStringCreateWithBytes(null, text.ptr, @intCast(text.len), kCFStringEncodingUTF8, 0);
    }

    fn release(self: *const Security, v: CFTypeRef) void {
        if (v != null) self.CFRelease(v);
    }

    fn dictionary(self: *const Security, keys: []const CFTypeRef, values: []const CFTypeRef) CFTypeRef {
        return self.CFDictionaryCreate(null, keys.ptr, values.ptr, @intCast(keys.len), self.key_callbacks, self.value_callbacks);
    }

    /// `kSecClass: kSecClassGenericPassword, kSecAttrService, kSecAttrAccount`
    /// plus `extra`, as a dictionary; null when CoreFoundation can't make it.
    fn query(self: *const Security, service: []const u8, account: []const u8, extra_key: CFTypeRef, extra_value: CFTypeRef) CFTypeRef {
        const s = self.string(service) orelse return null;
        defer self.release(s);
        const a = self.string(account) orelse return null;
        defer self.release(a);
        var keys = [_]CFTypeRef{ self.kSecClass, self.kSecAttrService, self.kSecAttrAccount, extra_key };
        var values = [_]CFTypeRef{ self.kSecClassGenericPassword, s, a, extra_value };
        const n: usize = if (extra_key != null) 4 else 3;
        return self.dictionary(keys[0..n], values[0..n]);
    }

    fn setGenericPassword(self: *const Security, service: []const u8, account: []const u8, password: []const u8) OSStatus {
        const data = self.CFDataCreate(null, password.ptr, @intCast(password.len)) orelse return -108; // memFullErr
        defer self.release(data);
        const add = self.query(service, account, self.kSecValueData, data) orelse return -108;
        defer self.release(add);
        const status = self.SecItemAdd(add, null);
        if (status != errSecDuplicateItem) return status;
        const find = self.query(service, account, null, null) orelse return -108;
        defer self.release(find);
        var k = [_]CFTypeRef{self.kSecValueData};
        var v = [_]CFTypeRef{data};
        const update = self.dictionary(&k, &v) orelse return -108;
        defer self.release(update);
        return self.SecItemUpdate(find, update);
    }

    fn getGenericPassword(self: *const Security, gpa: Allocator, service: []const u8, account: []const u8) !?[]u8 {
        const q = self.query(service, account, self.kSecReturnData, self.kCFBooleanTrue) orelse return null;
        defer self.release(q);
        var ret: CFTypeRef = null;
        if (self.SecItemCopyMatching(q, &ret) != 0) return null;
        defer self.release(ret);
        if (ret == null or self.CFGetTypeID(ret) != self.CFDataGetTypeID()) return null;
        const len: usize = @intCast(self.CFDataGetLength(ret));
        const out = try gpa.alloc(u8, len);
        if (len > 0) {
            const p = self.CFDataGetBytePtr(ret) orelse {
                gpa.free(out);
                return null;
            };
            @memcpy(out, p[0..len]);
        }
        return out;
    }

    fn deleteGenericPassword(self: *const Security, service: []const u8, account: []const u8) OSStatus {
        const q = self.query(service, account, null, null) orelse return -108;
        defer self.release(q);
        return self.SecItemDelete(q);
    }

    /// `security_framework::base::Error`'s Display: the system's message,
    /// else `error code N`.
    fn errorText(self: *const Security, status: OSStatus, buf: []u8) []const u8 {
        if (self.SecCopyErrorMessageString(status, null)) |s| {
            defer self.release(s);
            if (self.CFStringGetCString(s, buf.ptr, @intCast(buf.len), kCFStringEncodingUTF8) != 0) {
                return std.mem.sliceTo(buf, 0);
            }
        }
        return std.fmt.bufPrint(buf, "error code {d}", .{status}) catch "error";
    }
};

var security_mutex: Io.Mutex = .init;
var security_loaded: bool = false;
var security_fns: ?Security = null;

/// The Security framework, loaded once (null when it can't be).
fn security(io: Io) ?*const Security {
    if (comptime builtin.os.tag != .macos) return null;
    security_mutex.lockUncancelable(io);
    defer security_mutex.unlock(io);
    if (!security_loaded) {
        security_loaded = true;
        security_fns = loadSecurity();
    }
    return if (security_fns) |*s| s else null;
}

fn loadSecurity() ?Security {
    if (comptime builtin.os.tag != .macos) return null;
    // Kept open for the life of the process.
    var sec_lib = std.DynLib.open("/System/Library/Frameworks/Security.framework/Security") catch return null;
    var cf_lib = std.DynLib.open("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation") catch return null;
    var out: Security = undefined;
    const info = @typeInfo(Security).@"struct";
    inline for (info.field_names, info.field_types) |name, T| {
        const lib = if (comptime std.mem.startsWith(u8, name, "CF") or std.mem.startsWith(u8, name, "kCF")) &cf_lib else &sec_lib;
        if (comptime std.mem.eql(u8, name, "key_callbacks")) {
            out.key_callbacks = cf_lib.lookup(*const anyopaque, "kCFTypeDictionaryKeyCallBacks") orelse return null;
        } else if (comptime std.mem.eql(u8, name, "value_callbacks")) {
            out.value_callbacks = cf_lib.lookup(*const anyopaque, "kCFTypeDictionaryValueCallBacks") orelse return null;
        } else if (comptime T == CFTypeRef) {
            // An exported constant: the symbol is the variable holding it.
            const p = lib.lookup(*const CFTypeRef, name) orelse return null;
            @field(out, name) = p.*;
            if (@field(out, name) == null) return null;
        } else {
            @field(out, name) = lib.lookup(T, name) orelse return null;
        }
    }
    return out;
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

/// An absolute path under a test's temporary directory.
pub fn tmpPath(gpa: Allocator, tmp: *testing.TmpDir, name: []const u8) ![]u8 {
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
    defer gpa.free(base);
    return std.fs.path.join(gpa, &.{ base, name });
}

test "keystore: a file store keeps one private key until deleted" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(gpa, &tmp, "nested/k");
    var file: FileStore = .{ .path = path };
    defer gpa.free(path);
    const store = file.keyStore();
    try testing.expect(store.load(gpa, io) == null);
    const key = switch (store.loadOrCreate(gpa, io)) {
        .key => |k| k,
        .failed => |m| {
            defer gpa.free(m);
            return error.TestUnexpectedResult;
        },
    };
    const again = store.loadOrCreate(gpa, io).key;
    try testing.expectEqualSlices(u8, &key.secret_key.toBytes(), &again.secret_key.toBytes()); // created once
    if (builtin.os.tag != .windows) {
        const f = try tmp.dir.openFile(io, "nested/k", .{});
        defer f.close(io);
        const st = try f.stat(io);
        try testing.expectEqual(@as(std.posix.mode_t, 0o600), st.permissions.toMode() & 0o777);
    }
    // Nothing staged is left behind.
    var dir = try tmp.dir.openDir(io, "nested", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var names: usize = 0;
    while (try it.next(io)) |_| names += 1;
    try testing.expectEqual(@as(usize, 1), names);
    store.delete(io);
    try testing.expect(store.load(gpa, io) == null);
    const fresh = store.loadOrCreate(gpa, io).key;
    try testing.expect(!std.mem.eql(u8, &fresh.secret_key.toBytes(), &key.secret_key.toBytes()));
}

test "keystore: a file store that can't be written says so" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // The parent "directory" is a file.
    try tmp.dir.writeFile(io, .{ .sub_path = "blocker", .data = "x" });
    const path = try tmpPath(gpa, &tmp, "blocker/k");
    defer gpa.free(path);
    var file: FileStore = .{ .path = path };
    switch (file.keyStore().loadOrCreate(gpa, io)) {
        .key => return error.TestUnexpectedResult,
        .failed => |m| {
            defer gpa.free(m);
            try testing.expect(std.mem.startsWith(u8, m, "couldn't save the pairing key: "));
        },
    }
}

test "keystore: the memory store, its failures, and the override seam" {
    const gpa = testing.allocator;
    const io = testing.io;
    var mem: MemoryKeyStore = .{ .fail_write = "couldn't save the pairing key in the Keychain: User interaction is not allowed." };
    const store = mem.keyStore();
    switch (store.loadOrCreate(gpa, io)) {
        .key => return error.TestUnexpectedResult,
        .failed => |m| {
            defer gpa.free(m);
            try testing.expectEqualStrings("couldn't save the pairing key in the Keychain: User interaction is not allowed.", m);
        },
    }
    try testing.expect(!mem.has(io));
    mem.fail_write = null;
    const key = store.loadOrCreate(gpa, io).key;
    try testing.expect(mem.has(io));
    mem.fail_read = true;
    try testing.expect(store.load(gpa, io) == null);
    mem.fail_read = false;
    try testing.expectEqualSlices(u8, &key.secret_key.toBytes(), &store.load(gpa, io).?.secret_key.toBytes());

    override = store;
    defer override = null;
    const chosen = try forDataDir(gpa, "/synthetic/data");
    defer chosen.deinit(gpa); // borrowed: frees nothing
    try testing.expect(chosen.ptr == store.ptr);
    chosen.delete(io);
    try testing.expect(!mem.has(io));
    try testing.expectEqual(@as(usize, 1), mem.deletes);
}

test "keystore: the platform store for a data dir (built, never used)" {
    const gpa = testing.allocator;
    const store = try forDataDir(gpa, "/synthetic/data");
    defer store.deinit(gpa);
    if (builtin.os.tag == .macos) {
        const kc: *Keychain = @ptrCast(@alignCast(store.ptr));
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash("/synthetic/data", &digest, .{});
        var hex: [16]u8 = undefined;
        const want = try std.fmt.allocPrint(gpa, "client-key:{s}", .{wire.hexInto(&hex, digest[0..8])});
        defer gpa.free(want);
        try testing.expectEqualStrings(want, kc.account);
        try testing.expectEqual(@as(usize, "client-key:".len + 16), kc.account.len);
    } else {
        const fs: *FileStore = @ptrCast(@alignCast(store.ptr));
        try testing.expect(std.mem.endsWith(u8, fs.path, KEY_FILE));
    }
}

test "keystore: the Security framework loads at run time (no Keychain item touched)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const sec = security(testing.io) orelse return error.TestUnexpectedResult;
    var buf: [256]u8 = undefined;
    // errSecItemNotFound's message: text from the system, never a Keychain read.
    const text = sec.errorText(-25300, &buf);
    try testing.expect(text.len > 0);
    try testing.expect(!std.mem.startsWith(u8, text, "error code"));
}
