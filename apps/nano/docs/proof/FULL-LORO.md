# Retained-Loro local synchronization

This is a separate, explicitly **Rust-dependent** mode. It is not the
historical all-Zig `HZD1`/tail-only proof in `REPORT.md`.

## Boundary and versions

- Native Zig 0.17.0 calls the project-owned C ABI in `crates/nano-loro`.
- The ABI retains `harness-doc::SessionDoc`, `SegmentWriter`, command rules,
  the movable queue and locked **loro 1.13.9**. No shared dependency bump.
- The independent peer uses retained `harness-sync::ChatClient` over a real
  WebSocket, retained `harness-doc::SessionDoc`, and its SQLite store.
- The Swift format runner pins **loro-swift 1.13.3**, the iOS app's exact
  package/version. The local Worker retains **loro-crdt 1.13.7**.
- This is not an official loro-ffi Zig binding. Upstream is UniFFI-based and
  its inspected current README describes a newer 1.17.1 dependency. The
  pending-export API described there is not assumed available in 1.13.9.

The ABI is documented in `crates/nano-loro/include/harness_loro.h`. Handles
have one externally serialized owner. Inputs are borrowed spans; Rust-owned
return buffers are copied into the Zig allocator, then freed in Rust.
Success, causally pending, and error/panic results are distinct. Rust panics
do not unwind across the C boundary. Invalid non-null caller pointers remain
caller UB. The constructor-error regression checks native allocation cleanup.

Wire snapshots/updates are actual Loro binary documents. Frontiers are binary
**VersionVectors**, `oplog_vv().encode()`, not JSON or Frontiers encoding.
No chat2 wire rule or shared vector changed. Native transport currently uses
the existing HTTP rows/checkpoint surface; the retained Rust peer uses WS.

## Durability and history

`NLR1` is a private disk envelope, never sent to the Worker. It saves a real
Loro snapshot, unresolved raw incoming bytes, and the unsent local frontier
with the applied cursor in one SQLite snapshot row. Incoming pending bytes
are separate from outgoing-unacknowledged batches. The pinned core omits
pending imports from ordinary snapshots, so replay of those bytes matters.

The applied cursor stays held when dependencies are missing, including
across SQLite/process restart. The transport can read later contiguous rows
to find the prerequisite; a no-op row or own-write ACK cannot certify earlier
unresolved operations. Checkpoints cover only verified, caught-up state with
no pending imports, outstanding pushes or unsent local edits. Stable batch
IDs make a committed write followed by a lost ACK safe to resend.

Replica restart restores registry ownership before documents are loaded.
An unreferenced saved replica is not silently claimed as a locally hosted
chat. Existing HZD1 data is not automatically converted or joined to a new
Loro history: Loro mode refuses it with `LegacySnapshotNeedsMigration`.

## Run the local demo

From the integration repository root (Zig, Rust, Node 22+; macOS/Xcode for
the native app and pinned Swift check):

```sh
export HARNESS_HEAVY_BUILD_LOCK="$(pwd)/../zigfull.lock"
scripts/local-loro.sh check           # build and exercise actual sync
scripts/local-loro.sh check --keep    # retain only synthetic evidence
scripts/local-loro.sh up --phone      # isolated local Worker + two app profiles
scripts/local-loro.sh status
scripts/local-loro.sh down
```

`up --phone --no-app` exercises the same lifecycle without windows. All
profiles, homes, registry identities, repos and ports are synthetic and
isolated. Local authentication still requires explicit local mode, a literal
loopback origin, and the runner's valid opaque session. Release checks are
disabled and the installed-engine override is unset. No production deploy,
real profile, credentials or user simulator app are involved. Every subprocess
and socket scenario is bounded; cleanup targets only processes it started.

## Acceptance run

<!-- full-loro:run:begin -->
Tested implementation/compatibility commit: `cfad0db7`. Command:
`HARNESS_HEAVY_BUILD_LOCK="$(pwd)/../zigfull.lock" scripts/local-loro.sh check --keep`.
Result: **pass**, all ten acceptance/cleanup stages; no skipped stage.

| Stage | Result | Seconds | Evidence |
|---|---|---:|---|
| loopback Worker + explicit retained-Loro Zig engine | pass | 2.44 | `{"realLoro": true}` |
| retained Rust binary doc -> Worker rows -> native full history | pass | 6.02 | `{"seeded": 131,"dependentBeforePrerequisite": true,"pendingPersistedAcrossRestart": true,"appliedCursorHeld": 0,"headSeq": 2,"messages": 131,"first": "rust-0","middle": "rust-65"}` |
| Zig turn -> retained Rust ChatClient typed document | pass | 0.85 | `{"first": "rust-0","messages": 133,"middle": "rust-65","nativeUnicodeRoundtrip": true,"pendingPushes": 0,"remoteRunCount": 0}` |
| Rust document command executes once on Zig host and returns via Loro | pass | 3.04 | `{"first": "rust-0","messages": 135,"middle": "rust-65","nativeUnicodeRoundtrip": true,"pendingPushes": 0,"remoteRunCount": 1}` |
| second Zig device reads >64 messages from document, not tail | pass | 0.61 | `{"messages": 135,"first": "rust-0","middle": "rust-65"}` |
| offline concurrent Rust/Zig updates survive process and Worker restart | pass | 4.04 | `{"offlineBytes": 293,"pendingPushes": 1,"messagesAfterRestart": 137,"stableDuplicateSeq": 6,"remoteCommandCount": 1}` |
| host checkpoint trims log; fresh Rust and cold Zig catch up below floor | pass | 11.18 | `{"headSeq": 11,"checkpointSeq": 9,"seqFloor": 9,"freshRustCheckpoint": true,"coldZigMessages": 137}` |
| pinned Swift core reads native/Rust schema and sends a real Loro update | pass | 3.85 | `{"swiftPackage": "1.13.3","typedFields": true,"binaryVV": true,"messages": 137,"emittedRealUpdate": true,"updateSeq": 12,"appliedByRustAndZig": true}` |
| independent typed projections + mutual VV convergence | pass | 0.84 | `{"messages": 137,"mutualVV": true,"swiftUpdateApplied": true,"typedConverged": true,"zigCursor": 12}` |
| cleanup | pass | 0 | `{"processGroups": 3,"allPortsClosed": true}` |

The first/middle/last history checks use actual `WatchDocMessages`, not the
JSON tail. They are repeated on another device and after cold checkpoint
catchup. This engine currently returns full resets rather than exposing a
separate paginated history API; pagination UI behavior is not claimed.
The final independent typed projection and mutual VV check includes the
real Swift update at Worker sequence 12.
<!-- full-loro:run:end -->

## Before/after regressions and other gates

- Before the cursor fix, `retained Loro: an invalid import cannot advance the
  durable row cursor` failed with `InvalidImportWasAcknowledged`: the old
  client swallowed import errors and persisted an advanced cursor.
- Genuine retained-Rust snapshots/increments (131 messages, Unicode,
  reasoning/tool parts, queue and command metadata) failed under the legacy
  HZD1 implementation with `UnsupportedLegacyLoroBlob`. Linked-mode tests
  import them, update existing entries, handle duplicates, decode binary VVs,
  refuse HZD1 migration, and recover a pending B-before-A row through restart.
- The pending test holds the applied cursor across an intervening empty row,
  then imports the prerequisite as a later transport row. A separate ACK-gap
  test holds the cursor rather than jumping unread remote rows.
- Default legacy regression suite: 1523/1527 passed, four skipped, no failures.
  Linked retained-Loro focused suite: 23/23 passed. Rust ABI/core tests: 2/2.
- Unchanged shared chat2 vectors: Rust 5/5, native Zig 23/23 (including its
  imported standard tests), edge 16/16, Swift's existing runner 6/6.
  Edge local-auth tests: 7/7.
- The existing real-Worker local-edge regression also passed all nine stages
  with the linked engine: no-bearer 401, permitted-org 200, cross-org 403,
  forged-session startup rejection, relay/attachment/restart and cleanup
  (three active service groups stopped, 15 ports closed). No non-loopback
  connections were observed by that sampler; sampling is not a packet-level
  isolation proof.
- Full-mode `up --phone --no-app --ttl-minutes 3`, `status` and `down`
  passed under an isolated temporary TMPDIR/control pointer. Four owned
  process groups stopped and its temporary state was removed. No windows or
  real simulator apps were used by this lifecycle check.
- Default `zig build no-rust` passes. Supplying `-Dloro-lib` to that gate
  deliberately fails with the explicit retained-Rust diagnostic. No scanner
  exception was added to present Rust-dependent sync as all-Zig.

## Boundaries not claimed

This demonstrates document/format/transport convergence in synthetic local
runs, not production readiness or universal desktop/iOS parity. Native
updates are coalesced on the background HTTP cadence, not token-by-token
persistent per-chat WebSockets. The Swift check exercises the actual retained
core and typed schema plus real emitted updates; it does **not** launch the
iOS UI, iOS SessionStore lifecycle, or iOS network client.

There is no automatic HZD1 migration, native iOS/cross-platform archive
packaging, oversized-update splitting (the row cap is enforced), or new
large-history performance claim. The projection/persistence bridge currently
uses whole-document JSON materialization and a private JSON disk envelope;
large-document cost needs separate measurement before release. Some native
queue edits are coalesced into the next sync/persistence cycle rather than
being a new per-RPC fsync guarantee. The real command acceptance exercises
`run` and replay/restart deduplication, not every control-command variant.
Existing tool-output upload sidecars, peer-link caching and unrelated canned
RPC paths remain outside this change. No other session's experimental bridge
or dirty worktree was read or copied.
