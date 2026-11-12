//! browse's Connected apps protocol `v1-p256-sig` (justrach/browse
//! `docs/connected-apps.md`), ported from `crates/engine/src/browse_link/wire.rs`:
//! encodings, the pairing code, request signing and answer verification.
//! Pure (randomness comes from the `Io`), so the whole wire format is tested
//! here: `zig test browse_link_wire.zig`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;
const B64 = std.base64.standard;

pub const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;
pub const KeyPair = Ecdsa.KeyPair;
pub const PublicKey = Ecdsa.PublicKey;

pub const PROTOCOL = "v1-p256-sig";

/// Lowercase hex of `bytes` into `out` (`out.len == bytes.len * 2`).
pub fn hexInto(out: []u8, bytes: []const u8) []const u8 {
    const digits = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = digits[b >> 4];
        out[i * 2 + 1] = digits[b & 0x0f];
    }
    return out[0 .. bytes.len * 2];
}

pub fn hexAlloc(gpa: Allocator, bytes: []const u8) ![]u8 {
    const out = try gpa.alloc(u8, bytes.len * 2);
    _ = hexInto(out, bytes);
    return out;
}

/// `unhex`: pairs of hex digits (either case), else null.
pub fn unhex(gpa: Allocator, text: []const u8) !?[]u8 {
    if (text.len % 2 != 0) return null;
    const out = try gpa.alloc(u8, text.len / 2);
    errdefer gpa.free(out);
    var i: usize = 0;
    while (i < text.len) : (i += 2) {
        const hi = std.fmt.charToDigit(text[i], 16) catch {
            gpa.free(out);
            return null;
        };
        const lo = std.fmt.charToDigit(text[i + 1], 16) catch {
            gpa.free(out);
            return null;
        };
        out[i / 2] = (hi << 4) | lo;
    }
    return out;
}

/// 16 random bytes as 32 lowercase hex characters.
pub fn nonce(io: Io) [32]u8 {
    var bytes: [16]u8 = undefined;
    io.random(&bytes);
    var out: [32]u8 = undefined;
    _ = hexInto(&out, &bytes);
    return out;
}

pub fn newKey(io: Io) KeyPair {
    return KeyPair.generate(io);
}

/// `SigningKey::from_slice`: a big-endian scalar of 24 to 32 bytes (shorter
/// ones are left-padded), nonzero and below the group order.
pub fn keyFromBytes(bytes: []const u8) ?KeyPair {
    if (bytes.len < 24 or bytes.len > 32) return null;
    var padded: [32]u8 = @splat(0);
    @memcpy(padded[32 - bytes.len ..], bytes);
    const sk = Ecdsa.SecretKey.fromBytes(padded) catch return null;
    return KeyPair.fromSecretKey(sk) catch null;
}

/// Base64 (standard, padded) length of a 65-byte point.
pub const public_key_b64_len = B64.Encoder.calcSize(65);

/// Base64 (standard, padded) of the X9.63 uncompressed point, 65 bytes.
pub fn publicKeyB64(key: KeyPair) [public_key_b64_len]u8 {
    const point = key.public_key.toUncompressedSec1();
    var out: [public_key_b64_len]u8 = undefined;
    _ = B64.Encoder.encode(&out, &point);
    return out;
}

fn b64DecodeAlloc(gpa: Allocator, text: []const u8) !?[]u8 {
    const n = B64.Decoder.calcSizeForSlice(text) catch return null;
    const out = try gpa.alloc(u8, n);
    B64.Decoder.decode(out, text) catch {
        gpa.free(out);
        return null;
    };
    return out;
}

pub fn parsePublicKey(b64: []const u8) ?PublicKey {
    const n = B64.Decoder.calcSizeForSlice(b64) catch return null;
    if (n != 65) return null;
    var raw: [65]u8 = undefined;
    B64.Decoder.decode(&raw, b64) catch return null;
    return PublicKey.fromSec1(&raw) catch null;
}

/// The six digits both apps show: the first 4 bytes of
/// SHA-256(browse_key ‖ client_key ‖ nonce), raw bytes, as a big-endian u32,
/// mod 1,000,000.
pub fn pairingCode(gpa: Allocator, browse_key_b64: []const u8, client_key_b64: []const u8, nonce_hex: []const u8) !?[6]u8 {
    const browse = try b64DecodeAlloc(gpa, browse_key_b64) orelse return null;
    defer gpa.free(browse);
    const client = try b64DecodeAlloc(gpa, client_key_b64) orelse return null;
    defer gpa.free(client);
    const raw_nonce = try unhex(gpa, nonce_hex) orelse return null;
    defer gpa.free(raw_nonce);
    var h = Sha256.init(.{});
    h.update(browse);
    h.update(client);
    h.update(raw_nonce);
    var digest: [Sha256.digest_length]u8 = undefined;
    h.final(&digest);
    const n = std.mem.readInt(u32, digest[0..4], .big) % 1_000_000;
    var out: [6]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{d:0>6}", .{n}) catch unreachable;
    return out;
}

pub fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    var out: [64]u8 = undefined;
    _ = hexInto(&out, &digest);
    return out;
}

/// `METHOD|path|sha256hex(body)|timestamp|nonce|client_id`.
pub fn canonical(gpa: Allocator, method: []const u8, path: []const u8, body: []const u8, timestamp_ms: i64, nonce_text: []const u8, client_id: []const u8) ![]u8 {
    const digest = sha256Hex(body);
    return std.fmt.allocPrint(gpa, "{s}|{s}|{s}|{d}|{s}|{s}", .{ method, path, &digest, timestamp_ms, nonce_text, client_id });
}

/// Base64 of the ASN.1 DER ECDSA-SHA256 signature over `text`.
pub fn sign(gpa: Allocator, key: KeyPair, text: []const u8) ![]u8 {
    const signature = key.sign(text, null) catch return error.SigningFailed;
    var der_buf: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
    const der = signature.toDer(&der_buf);
    const out = try gpa.alloc(u8, B64.Encoder.calcSize(der.len));
    _ = B64.Encoder.encode(out, der);
    return out;
}

/// The headers of one signed request.
pub const SignedHeaders = struct {
    client_id: []u8,
    timestamp_ms: i64,
    nonce: [32]u8,
    signature: []u8,

    pub fn deinit(self: *SignedHeaders, gpa: Allocator) void {
        gpa.free(self.client_id);
        gpa.free(self.signature);
        self.* = undefined;
    }
};

pub fn signRequest(gpa: Allocator, io: Io, key: KeyPair, client_id: []const u8, path: []const u8, body: []const u8, timestamp_ms: i64) !SignedHeaders {
    const n = nonce(io);
    const text = try canonical(gpa, "POST", path, body, timestamp_ms, &n, client_id);
    defer gpa.free(text);
    const signature = try sign(gpa, key, text);
    errdefer gpa.free(signature);
    return .{
        .client_id = try gpa.dupe(u8, client_id),
        .timestamp_ms = timestamp_ms,
        .nonce = n,
        .signature = signature,
    };
}

/// A base64 DER signature over `text` checked against `key`.
pub fn verifyB64(key: PublicKey, text: []const u8, signature_b64: []const u8) bool {
    const trimmed = std.mem.trim(u8, signature_b64, " \t\r\n");
    const n = B64.Decoder.calcSizeForSlice(trimmed) catch return false;
    if (n > Ecdsa.Signature.der_encoded_length_max) return false;
    var der_buf: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
    B64.Decoder.decode(der_buf[0..n], trimmed) catch return false;
    const signature = Ecdsa.Signature.fromDer(der_buf[0..n]) catch return false;
    signature.verify(text, key) catch return false;
    return true;
}

/// browse signs every answer to a signed request over
/// `sha256hex(answer body)|request nonce`.
pub fn answerIsSigned(browse_key: PublicKey, body: []const u8, request_nonce: []const u8, signature_b64: ?[]const u8) bool {
    const sig = signature_b64 orelse return false;
    const digest = sha256Hex(body);
    var buf: [64 + 1 + 256]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{s}|{s}", .{ &digest, request_nonce }) catch return false;
    return verifyB64(browse_key, text, sig);
}

/// A per-run session id browse accepts: up to 64 of `[A-Za-z0-9._:-]`.
pub fn sessionId(gpa: Allocator, run_id: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "run:");
    var taken: usize = 0;
    // `chars()`: non-ASCII code points are never kept, so bytes suffice.
    for (run_id) |c| {
        if (taken == 58) break;
        if (std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == ':' or c == '-') {
            try out.append(gpa, c);
            taken += 1;
        }
    }
    return out.toOwnedSlice(gpa);
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "wire: keys round trip as 65-byte X9.63 points" {
    const key = newKey(testing.io);
    const b64 = publicKeyB64(key);
    var raw: [65]u8 = undefined;
    try B64.Decoder.decode(&raw, &b64);
    try testing.expectEqual(@as(u8, 0x04), raw[0]);
    const parsed = parsePublicKey(&b64).?;
    try testing.expectEqualSlices(u8, &key.public_key.toUncompressedSec1(), &parsed.toUncompressedSec1());
    try testing.expect(parsePublicKey("AAAA") == null);
    // The secret survives its 32 bytes (what the key store keeps).
    const again = keyFromBytes(&key.secret_key.toBytes()).?;
    try testing.expectEqualSlices(u8, &key.public_key.toUncompressedSec1(), &again.public_key.toUncompressedSec1());
    try testing.expect(keyFromBytes("") == null);
    const zero: [32]u8 = @splat(0);
    try testing.expect(keyFromBytes(&zero) == null);
}

test "wire: the pairing code follows the spec" {
    const gpa = testing.allocator;
    const b4: [65]u8 = @splat(0x04);
    const b5: [65]u8 = @splat(0x05);
    var browse: [public_key_b64_len]u8 = undefined;
    _ = B64.Encoder.encode(&browse, &b4);
    var client: [public_key_b64_len]u8 = undefined;
    _ = B64.Encoder.encode(&client, &b5);
    const n = "00112233445566778899aabbccddeeff";
    var h = Sha256.init(.{});
    h.update(&b4);
    h.update(&b5);
    h.update(&[_]u8{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff });
    var d: [32]u8 = undefined;
    h.final(&d);
    const expected = std.mem.readInt(u32, d[0..4], .big) % 1_000_000;
    var want: [6]u8 = undefined;
    _ = try std.fmt.bufPrint(&want, "{d:0>6}", .{expected});
    const code = (try pairingCode(gpa, &browse, &client, n)).?;
    try testing.expectEqualStrings(&want, &code);
    try testing.expect((try pairingCode(gpa, &browse, &client, "zz")) == null);
    try testing.expect((try pairingCode(gpa, "!!", &client, n)) == null);
}

test "wire: requests sign the canonical string and answers verify" {
    const gpa = testing.allocator;
    const io = testing.io;
    const client = newKey(io);
    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}";
    var headers = try signRequest(gpa, io, client, "c1", "/mcp", body, 1_790_000_000_000);
    defer headers.deinit(gpa);
    try testing.expectEqual(@as(usize, 32), headers.nonce.len);
    const text = try canonical(gpa, "POST", "/mcp", body, headers.timestamp_ms, &headers.nonce, "c1");
    defer gpa.free(text);
    try testing.expect(std.mem.startsWith(u8, text, "POST|/mcp|"));
    const tail = try std.fmt.allocPrint(gpa, "|1790000000000|{s}|c1", .{&headers.nonce});
    defer gpa.free(tail);
    try testing.expect(std.mem.endsWith(u8, text, tail));
    // What browse checks: the DER signature over the canonical string.
    try testing.expect(verifyB64(client.public_key, text, headers.signature));

    // browse's answer signature, and what a forged or tampered one does.
    const browse = newKey(io);
    const answer = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}";
    const answered = try std.fmt.allocPrint(gpa, "{s}|{s}", .{ &sha256Hex(answer), &headers.nonce });
    defer gpa.free(answered);
    const good = try sign(gpa, browse, answered);
    defer gpa.free(good);
    try testing.expect(answerIsSigned(browse.public_key, answer, &headers.nonce, good));
    try testing.expect(!answerIsSigned(browse.public_key, "{}", &headers.nonce, good)); // tampered body
    const other = nonce(io);
    try testing.expect(!answerIsSigned(browse.public_key, answer, &other, good)); // another request
    const squatter = try sign(gpa, newKey(io), answered);
    defer gpa.free(squatter);
    try testing.expect(!answerIsSigned(browse.public_key, answer, &headers.nonce, squatter)); // not the paired browse
    try testing.expect(!answerIsSigned(browse.public_key, answer, &headers.nonce, null));
    try testing.expect(!answerIsSigned(browse.public_key, answer, &headers.nonce, "not base64"));
}

test "wire: session ids fit browse's charset and length" {
    const gpa = testing.allocator;
    const id = try sessionId(gpa, "0190a1b2-c3d4/../ weird*chars");
    defer gpa.free(id);
    try testing.expect(id.len <= 64);
    for (id) |c| try testing.expect(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == ':' or c == '-');
    const long: [200]u8 = @splat('a');
    const capped = try sessionId(gpa, &long);
    defer gpa.free(capped);
    try testing.expectEqual(@as(usize, 62), capped.len);
}
