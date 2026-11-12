//! Engine-level tests for `WatchCheckoutChangeRequest` and
//! `MergeChangeRequest` against a temporary repository whose `origin` names a
//! synthetic GitHub repository, and a fake `gh` (a fixed shell script first
//! on PATH) that logs its arguments and answers from files. No network.
const std = @import("std");
const json = std.json;
const testing = std.testing;
const common = @import("rpcw_common.zig");
const Fixture = @import("rpcg_rpc_tests.zig").Fixture;

const fake_gh =
    \\#!/bin/sh
    \\printf '%s\n' "$*" >> "$GH_LOG"
    \\case "$1 $2" in
    \\  "pr list") cat "$GH_PRS" ;;
    \\  "repo view")
    \\    case "$*" in
    \\      *mergeCommitAllowed*) printf '{"mergeCommitAllowed":false,"squashMergeAllowed":true,"rebaseMergeAllowed":true}\n' ;;
    \\      *) printf '{"defaultBranchRef":{"name":"main"}}\n' ;;
    \\    esac ;;
    \\  "pr merge")
    \\    if [ -f "$GH_REFUSE" ]; then printf 'X Pull request synthetic-owner/synthetic-repo#4 is not mergeable: checks are pending.\n' >&2; exit 1; fi
    \\    printf '[{"number":4,"title":"Synthetic change","url":"https://github.com/synthetic-owner/synthetic-repo/pull/4","state":"MERGED","baseRefName":"main","headRefName":"feature","updatedAt":"2026-02-02T00:00:00Z","isCrossRepository":false,"headRepositoryOwner":{"login":"synthetic-owner"}}]\n' > "$GH_PRS" ;;
    \\  *) echo "unexpected: $*" >&2; exit 1 ;;
    \\esac
    \\
;

const open_pr =
    \\[{"number":4,"title":"Synthetic change","url":"https://github.com/synthetic-owner/synthetic-repo/pull/4","state":"OPEN","baseRefName":"main","headRefName":"feature","updatedAt":"2026-02-01T00:00:00Z","isCrossRepository":false,"headRepositoryOwner":{"login":"synthetic-owner"}}]
;

fn setup() !*Fixture {
    const f = try Fixture.init();
    const bin = try f.path("bin");
    const log = try f.path("gh.log");
    const prs = try f.path("prs.json");
    try f.t.sh("mkdir -p bin && cd repo && git remote add origin git@github.com:synthetic-owner/synthetic-repo.git && git checkout -q -b feature");
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = try f.path("bin/gh"), .data = fake_gh });
    try f.t.sh("chmod +x bin/gh");
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = prs, .data = open_pr });
    try f.t.env.map.put("PATH", try std.fmt.allocPrint(f.arena.allocator(), "{s}:/usr/bin:/bin", .{bin}));
    try f.t.env.map.put("HARNESS_NO_LOGIN_SHELL", "1");
    try f.t.env.map.put("GH_LOG", log);
    try f.t.env.map.put("GH_PRS", prs);
    try f.t.env.map.put("GH_REFUSE", try f.path("refuse"));
    return f;
}

fn ghLog(f: *Fixture) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(testing.io, try f.path("gh.log"), f.arena.allocator(), .limited(1 << 20)) catch "";
}

test "rpcg_change_requests WatchCheckoutChangeRequest resolves through gh and MergeChangeRequest merges" {
    if (comptime !std.process.can_spawn) return;
    const f = try setup();
    defer f.deinit();
    const repo = f.t.repo;

    try testing.expectEqualStrings("cwd is not a known checkout on this device", try f.err("WatchCheckoutChangeRequest", try f.params("{{\"cwd\":\"{s}\"}}", .{repo})));
    try testing.expectEqualStrings("missing field `cwd`", try f.err("WatchCheckoutChangeRequest", try f.params("{{}}", .{})));
    _ = try f.addChat("chat-1", "dev-synthetic", null, repo);

    var out = try f.call(31, "WatchCheckoutChangeRequest", try f.params("{{\"cwd\":\"{s}\"}}", .{repo}));
    try testing.expect(out.stream_items_json.checked);
    try testing.expectEqual(@as(usize, 0), out.stream_items_json.items.len);
    out.stream_items_json.deinit(testing.allocator);

    const first = try f.waitPushed(31, "\"changeRequest\":{");
    const v = try json.parseFromSliceLeaky(json.Value, f.arena.allocator(), first, .{});
    try testing.expectEqualStrings("feature", v.object.get("branch").?.string);
    try testing.expectEqualStrings("dev-synthetic", v.object.get("deviceId").?.string);
    const pr = v.object.get("changeRequest").?.object;
    try testing.expectEqualStrings("github", pr.get("provider").?.string);
    try testing.expectEqual(@as(i64, 4), pr.get("number").?.integer);
    try testing.expectEqualStrings("open", pr.get("state").?.string);
    try testing.expectEqualStrings("feature", pr.get("headRef").?.string);
    const log = try ghLog(f);
    try testing.expect(std.mem.indexOf(u8, log, "pr list --head synthetic-owner:feature --state all --limit 20 --json number,title,url,state,baseRefName,headRefName,updatedAt,isCrossRepository,headRepositoryOwner") != null);

    // A different number, a missing one, and the merge itself.
    const stale = try f.ok("MergeChangeRequest", try f.params("{{\"cwd\":\"{s}\",\"number\":9}}", .{repo}));
    try testing.expect(!stale.object.get("merged").?.bool);
    try testing.expectEqualStrings("#9 is no longer this branch's pull request", stale.object.get("message").?.string);
    try testing.expectEqualStrings("missing field `number`", try f.err("MergeChangeRequest", try f.params("{{\"cwd\":\"{s}\"}}", .{repo})));
    try testing.expectEqualStrings("cwd is not a known checkout on this device", try f.err("MergeChangeRequest", try f.params("{{\"cwd\":\"{s}\",\"number\":4}}", .{f.t.base})));

    try f.t.sh("touch refuse");
    const refused = try f.ok("MergeChangeRequest", try f.params("{{\"cwd\":\"{s}\",\"number\":4}}", .{repo}));
    try testing.expect(!refused.object.get("merged").?.bool);
    try testing.expectEqualStrings("Pull request synthetic-owner/synthetic-repo#4 is not mergeable: checks are pending.", refused.object.get("message").?.string);
    try f.t.sh("rm refuse");

    f.clearPushed();
    const merged = try f.ok("MergeChangeRequest", try f.params("{{\"cwd\":\"{s}\",\"number\":4}}", .{repo}));
    try testing.expect(merged.object.get("merged").?.bool);
    try testing.expectEqualStrings("Merged #4", merged.object.get("message").?.string);
    try testing.expect(std.mem.indexOf(u8, try ghLog(f), "pr merge 4 --repo github.com/synthetic-owner/synthetic-repo --squash") != null);
    // Watches refresh at once and show the merged state.
    _ = try f.waitPushed(31, "\"state\":\"merged\"");

    {
        f.host.mutex.lockUncancelable(testing.io);
        defer f.host.mutex.unlock(testing.io);
        f.host.cancelWatch(31);
    }
}

test "rpcg_change_requests a repository without a GitHub remote or gh reports why" {
    if (comptime !std.process.can_spawn) return;
    const f = try setup();
    defer f.deinit();
    const repo = f.t.repo;
    _ = try f.addChat("chat-1", "dev-synthetic", null, repo);
    try f.t.sh("cd repo && git remote set-url origin /srv/synthetic.git");
    try testing.expectEqualStrings("GitHub is unavailable for this repository", try f.err("MergeChangeRequest", try f.params("{{\"cwd\":\"{s}\",\"number\":4}}", .{repo})));
    try f.t.sh("cd repo && git remote set-url origin git@github.com:synthetic-owner/synthetic-repo.git && rm ../bin/gh");
    try testing.expectEqualStrings("GitHub CLI is not installed", try f.err("MergeChangeRequest", try f.params("{{\"cwd\":\"{s}\",\"number\":4}}", .{repo})));
    try f.t.sh("cd repo && git checkout -q --detach");
    try testing.expectEqualStrings("Git repository context is unavailable", try f.err("MergeChangeRequest", try f.params("{{\"cwd\":\"{s}\",\"number\":4}}", .{repo})));
}
