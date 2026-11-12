//! Where a sign-in is kept between launches: `session.json`'s body (the
//! refresh token, the user, the organization) as auth_host.zig writes it.
//!
//! - Desktop: the private `session.json` file, as before (auth_host's own
//!   writePrivateFile; `write` here declines and the caller writes it).
//! - iOS: the Keychain, a generic password under the Swift app's service
//!   with its accessibility class (after first unlock) and its access group
//!   (the default one, the app's identifier: no `kSecAttrAccessGroup`). A
//!   `session.json` an earlier build left is moved in once and deleted.
//! - Tests: `MemoryStore`, through `testing_store`.
//!
//! auth_host.zig calls `read`, `write` and `delete` at the three places it
//! used to touch the file; nothing else here knows about its format.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// The Swift app's Keychain service (apps/ios AuthClient.swift `Keychain`).
pub const service = "harness.codegraff.ios";
/// session.json's body, whole.
pub const session_account = "harnessSession";
/// The Swift app's own items: the cutover build (same bundle id, so the
/// same access group) signs in from its refresh token.
pub const legacy_refresh_account = "codegraffRefreshToken";
pub const legacy_access_account = "codegraffAccessToken";

/// session.json's size cap, as auth_host read it.
pub const max_bytes = 64 * 1024;

/// What a Keychain read found. `unavailable` isn't `missing`: before the
/// first unlock after a restart the Keychain can't be read, and a sign-in
/// that is there must not be taken for one that isn't.
pub const Read = union(enum) {
    found: []u8,
    missing,
    unavailable,

    pub fn tag(r: Read) std.meta.Tag(Read) {
        return r;
    }
};

/// A secure store: the iOS Keychain, or memory in tests.
pub const Secure = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        read: *const fn (ctx: *anyopaque, gpa: Allocator, account: []const u8) Read,
        /// Insert or update; false when the store refused (a locked phone).
        write: *const fn (ctx: *anyopaque, account: []const u8, bytes: []const u8) bool,
        delete: *const fn (ctx: *anyopaque, account: []const u8) void,
    };

    pub fn read(s: Secure, gpa: Allocator, account: []const u8) Read {
        return s.vtable.read(s.ctx, gpa, account);
    }
    pub fn write(s: Secure, account: []const u8, bytes: []const u8) bool {
        return s.vtable.write(s.ctx, account, bytes);
    }
    pub fn delete(s: Secure, account: []const u8) void {
        s.vtable.delete(s.ctx, account);
    }
};

// ── Rules ────────────────────────────────────────────────────────────────

pub const LoadPlan = enum {
    /// The Keychain's copy is the sign-in.
    use_secure,
    /// A file is there: move it into the Keychain, then delete it. A file
    /// only exists when the Keychain refused a write (or an earlier build
    /// wrote it), so it is always the newest copy.
    migrate_file,
    /// The Keychain can't be read yet (before first unlock): the file, if
    /// any, serves this launch and stays for the next.
    use_file,
    /// Nothing of ours: the Swift app's refresh token, if this build has
    /// its identity and so its Keychain items.
    try_legacy,
    none,
};

pub fn loadPlan(secure: std.meta.Tag(Read), file_present: bool) LoadPlan {
    if (file_present) return if (secure == .unavailable) .use_file else .migrate_file;
    return switch (secure) {
        .found => .use_secure,
        .missing => .try_legacy,
        .unavailable => .none,
    };
}

pub const WritePlan = enum {
    /// In the Keychain; a fallback file from earlier is now stale and goes.
    done_drop_file,
    /// The Keychain refused (locked): the caller writes the private file as
    /// before, so a rotated refresh token is never lost; the next load
    /// moves it in.
    fallback_file,
};

pub fn writePlan(secure_ok: bool) WritePlan {
    return if (secure_ok) .done_drop_file else .fallback_file;
}

/// A session.json body from the Swift app's refresh token alone: auth_host
/// restores it as "needs organization", and the person picks one.
pub fn legacyBody(gpa: Allocator, refresh_token: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{{\"refreshToken\":{f}}}", .{std.json.fmt(refresh_token, .{})});
}

/// Every Keychain item a sign-out removes: ours and the Swift app's, so a
/// signed-out phone isn't signed back in from the old token next launch.
pub const signed_out_accounts = [_][]const u8{ session_account, legacy_refresh_account, legacy_access_account };

// ── Operations ───────────────────────────────────────────────────────────

/// The session's body (owned by `gpa`), or null when there's none.
pub fn load(gpa: Allocator, io: Io, secure: Secure, path: []const u8) ?[]u8 {
    const kept = secure.read(gpa, session_account);
    const file = readFile(gpa, io, path);
    switch (loadPlan(kept.tag(), file != null)) {
        .use_secure => return kept.found,
        .migrate_file => {
            if (kept == .found) gpa.free(kept.found);
            const body = file.?;
            if (secure.write(session_account, body)) deleteFile(io, path);
            return body;
        },
        .use_file => return file,
        .none => return null,
        .try_legacy => {
            const legacy = secure.read(gpa, legacy_refresh_account);
            if (legacy != .found) return null;
            defer gpa.free(legacy.found);
            if (legacy.found.len == 0) return null;
            const body = legacyBody(gpa, legacy.found) catch return null;
            if (secure.write(session_account, body)) {
                secure.delete(legacy_refresh_account);
                secure.delete(legacy_access_account);
            }
            return body;
        },
    }
}

/// True when kept; false and the caller writes the file itself.
pub fn save(io: Io, secure: Secure, path: []const u8, body: []const u8) bool {
    switch (writePlan(secure.write(session_account, body))) {
        .done_drop_file => {
            deleteFile(io, path);
            return true;
        },
        .fallback_file => return false,
    }
}

pub fn clear(io: Io, secure: Secure, path: []const u8) void {
    for (signed_out_accounts) |account| secure.delete(account);
    deleteFile(io, path);
}

fn readFile(gpa: Allocator, io: Io, path: []const u8) ?[]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_bytes)) catch null;
}

fn deleteFile(io: Io, path: []const u8) void {
    Io.Dir.cwd().deleteFile(io, path) catch {};
}

// ── auth_host's hooks ────────────────────────────────────────────────────

/// Tests put a `MemoryStore` here; null otherwise.
pub var testing_store: ?Secure = null;

/// The secure store this build uses: the Keychain on iOS, none elsewhere.
pub fn platform() ?Secure {
    if (testing_store) |s| return s;
    if (comptime builtin.os.tag == .ios) return keychain.secure();
    return null;
}

/// session.json's body: the secure store's (migrating the file), or the
/// file's where there is no secure store.
pub fn read(gpa: Allocator, io: Io, path: []const u8) ?[]u8 {
    const secure = platform() orelse return readFile(gpa, io, path);
    return load(gpa, io, secure, path);
}

/// Whether the body was kept; false means the caller writes the file.
pub fn write(io: Io, path: []const u8, body: []const u8) bool {
    const secure = platform() orelse return false;
    return save(io, secure, path, body);
}

pub fn delete(io: Io, path: []const u8) void {
    const secure = platform() orelse return deleteFile(io, path);
    clear(io, secure, path);
}

// ── In memory, for tests ─────────────────────────────────────────────────

pub const MemoryStore = struct {
    gpa: Allocator,
    items: std.StringHashMapUnmanaged([]u8) = .empty,
    /// As a phone before its first unlock: reads unavailable, writes refused.
    locked: bool = false,

    pub fn deinit(m: *MemoryStore) void {
        var it = m.items.iterator();
        while (it.next()) |e| {
            m.gpa.free(e.key_ptr.*);
            m.gpa.free(e.value_ptr.*);
        }
        m.items.deinit(m.gpa);
    }

    pub fn secure(m: *MemoryStore) Secure {
        return .{ .ctx = m, .vtable = &.{ .read = readFn, .write = writeFn, .delete = deleteFn } };
    }

    pub fn get(m: *MemoryStore, account: []const u8) ?[]const u8 {
        return m.items.get(account);
    }

    fn readFn(ctx: *anyopaque, gpa: Allocator, account: []const u8) Read {
        const m: *MemoryStore = @ptrCast(@alignCast(ctx));
        if (m.locked) return .unavailable;
        const v = m.items.get(account) orelse return .missing;
        return .{ .found = gpa.dupe(u8, v) catch return .unavailable };
    }

    fn writeFn(ctx: *anyopaque, account: []const u8, bytes: []const u8) bool {
        const m: *MemoryStore = @ptrCast(@alignCast(ctx));
        if (m.locked) return false;
        const value = m.gpa.dupe(u8, bytes) catch return false;
        const gop = m.items.getOrPut(m.gpa, account) catch {
            m.gpa.free(value);
            return false;
        };
        if (gop.found_existing) {
            m.gpa.free(gop.value_ptr.*);
        } else {
            gop.key_ptr.* = m.gpa.dupe(u8, account) catch {
                m.items.removeByPtr(gop.key_ptr);
                m.gpa.free(value);
                return false;
            };
        }
        gop.value_ptr.* = value;
        return true;
    }

    fn deleteFn(ctx: *anyopaque, account: []const u8) void {
        const m: *MemoryStore = @ptrCast(@alignCast(ctx));
        if (m.items.fetchRemove(account)) |kv| {
            m.gpa.free(kv.key);
            m.gpa.free(kv.value);
        }
    }
};

// ── The iOS Keychain ─────────────────────────────────────────────────────

/// Security.framework's SecItem calls, with CoreFoundation dictionaries.
/// Referenced only from iOS builds (`platform`), so other targets never
/// link Security.
pub const keychain = struct {
    const CFTypeRef = *const anyopaque;
    const CFIndex = isize;
    const OSStatus = i32;
    const CFDictionaryKeyCallBacks = extern struct { version: CFIndex, retain: ?*const anyopaque, release: ?*const anyopaque, copy_description: ?*const anyopaque, equal: ?*const anyopaque, hash: ?*const anyopaque };
    const CFDictionaryValueCallBacks = extern struct { version: CFIndex, retain: ?*const anyopaque, release: ?*const anyopaque, copy_description: ?*const anyopaque, equal: ?*const anyopaque };

    extern "c" const kCFTypeDictionaryKeyCallBacks: CFDictionaryKeyCallBacks;
    extern "c" const kCFTypeDictionaryValueCallBacks: CFDictionaryValueCallBacks;
    extern "c" const kCFBooleanTrue: CFTypeRef;
    extern "c" fn CFDictionaryCreateMutable(allocator: ?*anyopaque, capacity: CFIndex, keys: *const CFDictionaryKeyCallBacks, values: *const CFDictionaryValueCallBacks) ?*anyopaque;
    extern "c" fn CFDictionarySetValue(dict: *anyopaque, key: CFTypeRef, value: CFTypeRef) void;
    extern "c" fn CFStringCreateWithBytes(allocator: ?*anyopaque, bytes: [*]const u8, len: CFIndex, encoding: u32, external: u8) ?*anyopaque;
    extern "c" fn CFDataCreate(allocator: ?*anyopaque, bytes: [*]const u8, len: CFIndex) ?*anyopaque;
    extern "c" fn CFDataGetLength(data: CFTypeRef) CFIndex;
    extern "c" fn CFDataGetBytePtr(data: CFTypeRef) [*]const u8;
    extern "c" fn CFRelease(obj: CFTypeRef) void;

    extern "c" const kSecClass: CFTypeRef;
    extern "c" const kSecClassGenericPassword: CFTypeRef;
    extern "c" const kSecAttrService: CFTypeRef;
    extern "c" const kSecAttrAccount: CFTypeRef;
    extern "c" const kSecReturnData: CFTypeRef;
    extern "c" const kSecMatchLimit: CFTypeRef;
    extern "c" const kSecMatchLimitOne: CFTypeRef;
    extern "c" const kSecValueData: CFTypeRef;
    extern "c" const kSecAttrAccessible: CFTypeRef;
    extern "c" const kSecAttrAccessibleAfterFirstUnlock: CFTypeRef;
    extern "c" fn SecItemCopyMatching(query: CFTypeRef, result: *?CFTypeRef) OSStatus;
    extern "c" fn SecItemAdd(attributes: CFTypeRef, result: ?*?CFTypeRef) OSStatus;
    extern "c" fn SecItemUpdate(query: CFTypeRef, attributes: CFTypeRef) OSStatus;
    extern "c" fn SecItemDelete(query: CFTypeRef) OSStatus;

    const errSecSuccess: OSStatus = 0;
    const errSecItemNotFound: OSStatus = -25300;
    const utf8: u32 = 0x08000100;

    var anchor: u8 = 0;

    pub fn secure() Secure {
        return .{ .ctx = &anchor, .vtable = &.{ .read = readFn, .write = writeFn, .delete = deleteFn } };
    }

    fn cfString(text: []const u8) ?*anyopaque {
        return CFStringCreateWithBytes(null, text.ptr, @intCast(text.len), utf8, 0);
    }

    /// The item's identity: generic password, Swift's service, `account`.
    fn query(account: []const u8) ?*anyopaque {
        const dict = CFDictionaryCreateMutable(null, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks) orelse return null;
        const svc = cfString(service) orelse {
            CFRelease(dict);
            return null;
        };
        defer CFRelease(svc);
        const acc = cfString(account) orelse {
            CFRelease(dict);
            return null;
        };
        defer CFRelease(acc);
        CFDictionarySetValue(dict, kSecClass, kSecClassGenericPassword);
        CFDictionarySetValue(dict, kSecAttrService, svc);
        CFDictionarySetValue(dict, kSecAttrAccount, acc);
        return dict;
    }

    fn readFn(_: *anyopaque, gpa: Allocator, account: []const u8) Read {
        const q = query(account) orelse return .unavailable;
        defer CFRelease(q);
        CFDictionarySetValue(q, kSecReturnData, kCFBooleanTrue);
        CFDictionarySetValue(q, kSecMatchLimit, kSecMatchLimitOne);
        var result: ?CFTypeRef = null;
        const status = SecItemCopyMatching(q, &result);
        if (status == errSecItemNotFound) return .missing;
        if (status != errSecSuccess) return .unavailable;
        const data = result orelse return .missing;
        defer CFRelease(data);
        const len: usize = @intCast(CFDataGetLength(data));
        return .{ .found = gpa.dupe(u8, CFDataGetBytePtr(data)[0..len]) catch return .unavailable };
    }

    /// Update in place, else add: delete-then-add would leave a gap where a
    /// kill loses the item. The accessibility class goes with every update,
    /// as the Swift app's does.
    fn writeFn(_: *anyopaque, account: []const u8, bytes: []const u8) bool {
        const q = query(account) orelse return false;
        defer CFRelease(q);
        const data = CFDataCreate(null, bytes.ptr, @intCast(bytes.len)) orelse return false;
        defer CFRelease(data);
        const attrs = CFDictionaryCreateMutable(null, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks) orelse return false;
        defer CFRelease(attrs);
        CFDictionarySetValue(attrs, kSecValueData, data);
        CFDictionarySetValue(attrs, kSecAttrAccessible, kSecAttrAccessibleAfterFirstUnlock);
        const updated = SecItemUpdate(q, attrs);
        if (updated == errSecSuccess) return true;
        if (updated != errSecItemNotFound) return false;
        CFDictionarySetValue(q, kSecValueData, data);
        CFDictionarySetValue(q, kSecAttrAccessible, kSecAttrAccessibleAfterFirstUnlock);
        return SecItemAdd(q, null) == errSecSuccess;
    }

    fn deleteFn(_: *anyopaque, account: []const u8) void {
        const q = query(account) orelse return;
        defer CFRelease(q);
        _ = SecItemDelete(q);
    }
};

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "loadPlan: the file is always newest, the Keychain otherwise, never guessing while locked" {
    try testing.expectEqual(LoadPlan.use_secure, loadPlan(.found, false));
    try testing.expectEqual(LoadPlan.migrate_file, loadPlan(.found, true));
    try testing.expectEqual(LoadPlan.migrate_file, loadPlan(.missing, true));
    try testing.expectEqual(LoadPlan.use_file, loadPlan(.unavailable, true));
    try testing.expectEqual(LoadPlan.try_legacy, loadPlan(.missing, false));
    try testing.expectEqual(LoadPlan.none, loadPlan(.unavailable, false));
    try testing.expectEqual(WritePlan.done_drop_file, writePlan(true));
    try testing.expectEqual(WritePlan.fallback_file, writePlan(false));
}

test "legacyBody escapes the token as JSON" {
    const body = try legacyBody(testing.allocator, "rt-\"synthetic\"");
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("{\"refreshToken\":\"rt-\\\"synthetic\\\"\"}", body);
}

const Fixture = struct {
    tmp: testing.TmpDir,
    path_buf: [512]u8 = undefined,
    path: []const u8 = "",

    fn init(f: *Fixture) !void {
        f.tmp = testing.tmpDir(.{});
        var dir_buf: [400]u8 = undefined;
        const n = try f.tmp.dir.realPath(testing.io, &dir_buf);
        f.path = try std.fmt.bufPrint(&f.path_buf, "{s}/session.json", .{dir_buf[0..n]});
    }

    fn writeFile(f: *Fixture, body: []const u8) !void {
        try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = f.path, .data = body });
    }

    fn fileExists(f: *Fixture) bool {
        const raw = readFile(testing.allocator, testing.io, f.path) orelse return false;
        testing.allocator.free(raw);
        return true;
    }
};

test "an existing session.json moves into the Keychain once and is deleted" {
    var f: Fixture = .{ .tmp = undefined };
    try f.init();
    defer f.tmp.cleanup();
    var mem: MemoryStore = .{ .gpa = testing.allocator };
    defer mem.deinit();
    const body = "{\"refreshToken\":\"rt-synthetic-1\",\"orgId\":\"org-synth\"}";
    try f.writeFile(body);

    const got = load(testing.allocator, testing.io, mem.secure(), f.path).?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(body, got);
    try testing.expectEqualStrings(body, mem.get(session_account).?);
    try testing.expect(!f.fileExists());

    // The next launch reads the Keychain; there is no file to move again.
    const again = load(testing.allocator, testing.io, mem.secure(), f.path).?;
    defer testing.allocator.free(again);
    try testing.expectEqualStrings(body, again);
}

test "a locked Keychain keeps the file and loses no rotated token" {
    var f: Fixture = .{ .tmp = undefined };
    try f.init();
    defer f.tmp.cleanup();
    var mem: MemoryStore = .{ .gpa = testing.allocator };
    defer mem.deinit();
    mem.locked = true;
    // A write while locked: declined, so auth_host writes the file.
    try testing.expect(!save(testing.io, mem.secure(), f.path, "{\"refreshToken\":\"rt-rotated\"}"));
    try f.writeFile("{\"refreshToken\":\"rt-rotated\"}");
    // Still locked: the file serves and stays.
    const locked_read = load(testing.allocator, testing.io, mem.secure(), f.path).?;
    testing.allocator.free(locked_read);
    try testing.expect(f.fileExists());
    // Unlocked: it moves in.
    mem.locked = false;
    const read_back = load(testing.allocator, testing.io, mem.secure(), f.path).?;
    defer testing.allocator.free(read_back);
    try testing.expectEqualStrings("{\"refreshToken\":\"rt-rotated\"}", mem.get(session_account).?);
    try testing.expect(!f.fileExists());
}

test "a fallback file is newer than the Keychain's copy, and a good write drops it" {
    var f: Fixture = .{ .tmp = undefined };
    try f.init();
    defer f.tmp.cleanup();
    var mem: MemoryStore = .{ .gpa = testing.allocator };
    defer mem.deinit();
    try testing.expect(save(testing.io, mem.secure(), f.path, "{\"refreshToken\":\"old\"}"));
    try f.writeFile("{\"refreshToken\":\"new\"}");
    const got = load(testing.allocator, testing.io, mem.secure(), f.path).?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("{\"refreshToken\":\"new\"}", got);
    try testing.expectEqualStrings("{\"refreshToken\":\"new\"}", mem.get(session_account).?);

    try f.writeFile("{\"refreshToken\":\"stale\"}");
    try testing.expect(save(testing.io, mem.secure(), f.path, "{\"refreshToken\":\"newest\"}"));
    try testing.expect(!f.fileExists());
}

test "the Swift app's refresh token signs the cutover build in, and sign-out removes it" {
    var f: Fixture = .{ .tmp = undefined };
    try f.init();
    defer f.tmp.cleanup();
    var mem: MemoryStore = .{ .gpa = testing.allocator };
    defer mem.deinit();
    try testing.expect(mem.secure().write(legacy_refresh_account, "rt-swift-synthetic"));
    try testing.expect(mem.secure().write(legacy_access_account, "at-swift-synthetic"));

    const got = load(testing.allocator, testing.io, mem.secure(), f.path).?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("{\"refreshToken\":\"rt-swift-synthetic\"}", got);
    try testing.expectEqualStrings(got, mem.get(session_account).?);
    // Imported once: the spent Swift items don't come back.
    try testing.expect(mem.get(legacy_refresh_account) == null);
    try testing.expect(mem.get(legacy_access_account) == null);

    try testing.expect(mem.secure().write(legacy_refresh_account, "rt-swift-again"));
    try f.writeFile("{}");
    clear(testing.io, mem.secure(), f.path);
    for (signed_out_accounts) |account| try testing.expect(mem.get(account) == null);
    try testing.expect(!f.fileExists());
    try testing.expectEqual(@as(?[]u8, null), load(testing.allocator, testing.io, mem.secure(), f.path));
}

test "the hooks use the file where there is no secure store" {
    var f: Fixture = .{ .tmp = undefined };
    try f.init();
    defer f.tmp.cleanup();
    const saved = testing_store;
    defer testing_store = saved;
    testing_store = null;
    if (builtin.os.tag == .ios) return error.SkipZigTest;
    try testing.expect(!write(testing.io, f.path, "{\"refreshToken\":\"desk\"}"));
    try f.writeFile("{\"refreshToken\":\"desk\"}");
    const got = read(testing.allocator, testing.io, f.path).?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("{\"refreshToken\":\"desk\"}", got);
    delete(testing.io, f.path);
    try testing.expect(!f.fileExists());

    var mem: MemoryStore = .{ .gpa = testing.allocator };
    defer mem.deinit();
    testing_store = mem.secure();
    try testing.expect(write(testing.io, f.path, "{\"refreshToken\":\"kept\"}"));
    try testing.expectEqualStrings("{\"refreshToken\":\"kept\"}", mem.get(session_account).?);
}
