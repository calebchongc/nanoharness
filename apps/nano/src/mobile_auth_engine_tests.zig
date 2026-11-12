//! The phone's sign-in against an in-process loopback server playing the
//! edge: `SignIn {"mobile":true}` (random PKCE, the iOS redirect), the
//! `harness://callback` the browser step returns, `CompleteSignIn`'s
//! exchange, the organization list and choice, and account deletion
//! refused then done. Synthetic accounts only.
const std = @import("std");
const json = std.json;
const testing = std.testing;
const engine_host = @import("engine_host.zig");
const auth_host = @import("auth_host.zig");
const mobile_auth = @import("mobile_auth.zig");

const org_less_jwt = "e30.eyJzdWIiOiJ1X2xpdmUiLCJpYXQiOjEwMDAsImV4cCI6NDYwMH0.sig";
const org_jwt = "e30.eyJzdWIiOiJ1X2xpdmUiLCJpYXQiOjEwMDAsImV4cCI6NDYwMCwib3JnX2lkIjoib3JnXzEifQ.sig";

const Edge = struct {
    srv: std.Io.net.Server,
    io: std.Io,
    stop: std.atomic.Value(bool) = .init(false),
    deletes: std.atomic.Value(u32) = .init(0),
    orgs_fail: std.atomic.Value(bool) = .init(false),
    /// The last `/auth/exchange` body, for its verifier and redirect.
    exchange_body: [1024]u8 = undefined,
    exchange_len: usize = 0,
    /// The last delete's refresh credential.
    delete_body: [512]u8 = undefined,
    delete_len: usize = 0,

    fn run(e: *Edge) void {
        while (!e.stop.load(.acquire)) {
            var stream = e.srv.accept(e.io) catch return;
            defer stream.close(e.io);
            if (e.stop.load(.acquire)) return;
            var rbuf: [8192]u8 = undefined;
            var wbuf: [4096]u8 = undefined;
            var reader = stream.reader(e.io, &rbuf);
            var writer = stream.writer(e.io, &wbuf);
            const line_raw = reader.interface.takeDelimiterInclusive('\n') catch continue;
            var line_buf: [256]u8 = undefined;
            const ln = @min(line_raw.len, line_buf.len);
            @memcpy(line_buf[0..ln], line_raw[0..ln]);
            const req_line = line_buf[0..ln];
            var content_len: usize = 0;
            while (true) {
                const h = reader.interface.takeDelimiterInclusive('\n') catch break;
                const t = std.mem.trimEnd(u8, h, "\r\n");
                if (t.len == 0) break;
                if (std.ascii.startsWithIgnoreCase(t, "content-length:"))
                    content_len = std.fmt.parseInt(usize, std.mem.trim(u8, t["content-length:".len..], " \t"), 10) catch 0;
            }
            var body_buf: [2048]u8 = undefined;
            const blen = @min(content_len, body_buf.len);
            reader.interface.readSliceAll(body_buf[0..blen]) catch {};
            const body = body_buf[0..blen];

            var status: u16 = 200;
            const reply: []const u8 = if (std.mem.indexOf(u8, req_line, "/auth/exchange") != null) blk: {
                @memcpy(e.exchange_body[0..@min(body.len, e.exchange_body.len)], body[0..@min(body.len, e.exchange_body.len)]);
                e.exchange_len = @min(body.len, e.exchange_body.len);
                break :blk "{\"user\":{\"id\":\"u_synth\",\"email\":\"sam@example.com\",\"firstName\":\"Sam\",\"lastName\":\"Rivera\"},\"accessToken\":\"" ++ org_less_jwt ++ "\",\"refreshToken\":\"rt-1\"}";
            } else if (std.mem.indexOf(u8, req_line, "/auth/orgs") != null) blk: {
                if (e.orgs_fail.load(.acquire)) {
                    status = 503;
                    break :blk "{\"error\":\"unavailable\"}";
                }
                break :blk "{\"orgs\":[{\"id\":\"om_1\",\"organizationId\":\"org_1\",\"name\":\"Sample Studio\"},{\"id\":\"om_2\",\"organizationId\":\"org_2\",\"name\":\"Personal\"}]}";
            } else if (std.mem.indexOf(u8, req_line, "/auth/refresh") != null)
                "{\"accessToken\":\"" ++ org_jwt ++ "\",\"refreshToken\":\"rt-2\"}"
            else if (std.mem.indexOf(u8, req_line, "/auth/account/delete") != null) blk: {
                @memcpy(e.delete_body[0..@min(body.len, e.delete_body.len)], body[0..@min(body.len, e.delete_body.len)]);
                e.delete_len = @min(body.len, e.delete_body.len);
                if (e.deletes.fetchAdd(1, .acq_rel) == 0) {
                    status = 409;
                    break :blk "{\"error\":\"active_subscription\",\"message\":\"Cancel your plan first.\",\"tokens\":{\"accessToken\":\"" ++ org_jwt ++ "\",\"refreshToken\":\"rt-rotated\"}}";
                }
                break :blk "{\"deleted\":true}";
            } else blk: {
                status = 404;
                break :blk "{}";
            };
            writer.interface.print("HTTP/1.1 {d} X\r\ncontent-type: application/json\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n{s}", .{ status, reply.len, reply }) catch continue;
            writer.interface.flush() catch continue;
        }
    }
};

fn call(host: *engine_host.EngineHost, a: std.mem.Allocator, method: []const u8, params: []const u8) !engine_host.RpcOutcome {
    const p = try json.parseFromSliceLeaky(json.Value, a, params, .{});
    return host.handle(method, p);
}

test "mobile sign-in: random PKCE to the iOS redirect, callback, exchange, org choice, then account deletion against a loopback edge" {
    const gpa = testing.allocator;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var edge: Edge = .{ .srv = try addr.listen(io, .{ .reuse_address = true }), .io = io };
    defer edge.srv.deinit(io);
    const port = edge.srv.socket.address.getPort();
    const th = try std.Thread.spawn(.{}, Edge.run, .{&edge});
    defer {
        edge.stop.store(true, .release);
        if (std.Io.net.IpAddress.parseIp4("127.0.0.1", port)) |wake| {
            if (wake.connect(io, .{ .mode = .stream })) |s| s.close(io) else |_| {}
        } else |_| {}
        th.join();
    }

    const dir = "/tmp/harness-zig-mobile-auth-test";
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    std.Io.Dir.cwd().deleteFile(io, dir ++ "/session.json") catch {};

    var host = try engine_host.EngineHost.init(gpa, "dev-phone", "Test Phone");
    defer host.deinit();
    host.io = io;
    const edge_url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{port});
    try host.auth.configureCodegraff(edge_url, "cg_client_test", "https://codegraff.example", dir);

    // 1. Two starts: each a fresh random state and verifier, to the iOS redirect.
    const first = try call(&host, a, "SignIn", "{\"mobile\":true}");
    defer gpa.free(first.unary_json);
    const second = try call(&host, a, "SignIn", "{\"mobile\":true}");
    defer gpa.free(second.unary_json);
    const url1 = (try json.parseFromSliceLeaky(json.Value, a, first.unary_json, .{})).object.get("url").?.string;
    const url2 = (try json.parseFromSliceLeaky(json.Value, a, second.unary_json, .{})).object.get("url").?.string;
    var redirect_enc_buf: [160]u8 = undefined;
    const redirect_enc = try std.fmt.bufPrint(&redirect_enc_buf, "redirect_uri=http%3A%2F%2F127.0.0.1%3A{d}%2Fauth%2Fios%2Fcallback", .{port});
    try testing.expect(std.mem.indexOf(u8, url2, redirect_enc) != null);
    try testing.expect(std.mem.indexOf(u8, url2, "code_challenge_method=S256") != null);
    var s1b: [128]u8 = undefined;
    var s2b: [128]u8 = undefined;
    const state1 = mobile_auth.queryParam(&s1b, url1, "state").?;
    const state = mobile_auth.queryParam(&s2b, url2, "state").?;
    try testing.expectEqual(@as(usize, 32), state.len);
    try testing.expect(!std.mem.eql(u8, state1, state));
    var chb: [128]u8 = undefined;
    const challenge = mobile_auth.queryParam(&chb, url2, "code_challenge").?;

    // 2. The browser step returns; the first attempt's link is someone else's.
    var cb_url_buf: [256]u8 = undefined;
    var code_buf: [128]u8 = undefined;
    var reason_buf: [128]u8 = undefined;
    const stale = try std.fmt.bufPrint(&cb_url_buf, "harness://callback?code=c_old&state={s}", .{state1});
    try testing.expectEqual(mobile_auth.CallbackError.state_mismatch, mobile_auth.readCallback(&code_buf, &reason_buf, stale, state, 0, 1).failed.err);
    const cb = try std.fmt.bufPrint(&cb_url_buf, "harness://callback?code=c_ok&state={s}", .{state});
    const code = mobile_auth.readCallback(&code_buf, &reason_buf, cb, state, 0, 1).code;
    var joined_buf: [256]u8 = undefined;
    const joined = mobile_auth.completeCode(&joined_buf, state, code).?;

    // 3. CompleteSignIn exchanges with the verifier whose S256 is the challenge, on the iOS redirect.
    const params = try std.fmt.allocPrint(a, "{{\"code\":{f}}}", .{json.fmt(joined, .{})});
    const done = try call(&host, a, "CompleteSignIn", params);
    try testing.expect(done == .unary_json);
    gpa.free(done.unary_json);
    try testing.expectEqual(auth_host.AuthPhase.needs_organization, host.auth.phase);
    try testing.expectEqualStrings("Sam Rivera", host.auth.user_name.?);
    const ex = try json.parseFromSliceLeaky(json.Value, a, edge.exchange_body[0..edge.exchange_len], .{});
    var want_ch: [43]u8 = undefined;
    try testing.expectEqualStrings(challenge, auth_host.pkceChallengeS256(ex.object.get("codeVerifier").?.string, &want_ch));
    try testing.expectEqualStrings("c_ok", ex.object.get("code").?.string);
    try testing.expect(std.mem.endsWith(u8, ex.object.get("redirectUri").?.string, "/auth/ios/callback"));
    try testing.expect(!std.mem.eql(u8, "zig_pkce_verifier_0123456789abcdef0123456789abcdef", ex.object.get("codeVerifier").?.string));

    // 4. Two organizations: the picker; a failing edge offers none rather than a made-up one.
    edge.orgs_fail.store(true, .release);
    try testing.expect((try call(&host, a, "ListOrgs", "{}")) == .err);
    edge.orgs_fail.store(false, .release);
    const orgs_r = try call(&host, a, "ListOrgs", "{}");
    defer gpa.free(orgs_r.unary_json);
    const orgs = try mobile_auth.parseOrgs(a, try json.parseFromSliceLeaky(json.Value, a, orgs_r.unary_json, .{}));
    try testing.expect(mobile_auth.orgPlan(orgs.len) == .pick);
    const sel = try call(&host, a, "SelectOrg", "{\"organizationId\":\"org_1\"}");
    try testing.expect(sel == .unary_json);
    gpa.free(sel.unary_json);
    try testing.expectEqual(auth_host.AuthPhase.signed_in, host.auth.phase);
    try testing.expectEqualStrings("rt-2", host.auth.refresh_token.?);

    // 5. Deletion refused: the Swift copy, and the rotated pair kept.
    const refused = try call(&host, a, "DeleteAccount", "{}");
    defer gpa.free(refused.unary_json);
    const rv = try json.parseFromSliceLeaky(json.Value, a, refused.unary_json, .{});
    try testing.expect(!rv.object.get("deleted").?.bool);
    try testing.expectEqualStrings("Cancel your plan first.", rv.object.get("message").?.string);
    try testing.expectEqualStrings("rt-rotated", host.auth.refresh_token.?);
    try testing.expect(std.mem.indexOf(u8, edge.delete_body[0..edge.delete_len], "\"confirm\":\"delete\"") != null);
    try testing.expect(host.auth.signed_in);

    // 6. Deleted: signed out here.
    const deleted = try call(&host, a, "DeleteAccount", "{}");
    defer gpa.free(deleted.unary_json);
    try testing.expectEqualStrings("{\"deleted\":true}", deleted.unary_json);
    try testing.expectEqual(auth_host.AuthPhase.signed_out, host.auth.phase);
    try testing.expect(host.auth.refresh_token == null);
}

test "Graff compaction: the engine keeps the `pct` the apps send, and null hands the choice back to graff" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var host = try engine_host.EngineHost.init(gpa, "dev-c", "Box");
    defer host.deinit();
    const set70 = try call(&host, a, "SetGraffCompactAt", "{\"pct\":70}");
    defer gpa.free(set70.unary_json);
    try testing.expectEqualStrings("70", set70.unary_json);
    const reset = try call(&host, a, "SetGraffCompactAt", "{\"pct\":null}");
    defer gpa.free(reset.unary_json);
    try testing.expectEqualStrings("null", reset.unary_json); // Rust: `None`, graff picks its own default (`registry.rs`)
}
