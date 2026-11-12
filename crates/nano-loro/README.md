# Retained Loro boundary for Nano

This is a **project-owned C ABI**, not an official `loro-ffi` Zig binding.
It uses the existing `harness-doc::SessionDoc`, `SegmentWriter`, movable
queue and command rules, backed by the workspace's locked **loro 1.13.9**.
No shared Loro dependency was upgraded. The iOS client pins `loro-swift
1.13.3`; the compatibility runner pins the same package.

Upstream [loro-ffi](https://github.com/loro-dev/loro-ffi) generates UniFFI
bindings and does not list Zig as a target. Adapting those generated
bindings would add a second ABI and generic-container translation layer.
The smaller boundary here keeps Harness's existing schema and core. Current
upstream documentation describes a newer 1.17.1 core and a pending-export
API; **that API is not available in the retained 1.13.9 core** and is not
assumed here.

## Build boundary

From the repository root:

```sh
export HARNESS_HEAVY_BUILD_LOCK="$(pwd)/../zigfull.lock"
scripts/build-loro.sh
cd apps/nano
../../scripts/heavy-build.sh zig build install \
  -Dloro-lib="$(cd ../.. && pwd)/target/nano-loro/debug/libharness_nano_loro.a"
```

Or use `scripts/local-loro.sh build` / `scripts/local-loro.sh check`.
This mode intentionally **requires Rust**. Default Nano builds remain the
legacy/offline `HZD1` mode and do not gain Loro interoperability merely by
retaining files. `zig build no-rust -Dloro-lib=...` explicitly fails; the
zero-Rust scanner has not been loosened to exempt the bridge. The historical
`prove-zig.sh` proof concerns the legacy/offline mode, not this mode.

## ABI and persistence

`include/harness_loro.h` is the boundary. A document is an opaque,
non-concurrently-used handle. Input pointer/length spans are borrowed.
Return buffers are Rust-owned boxed slices, copied by the Zig wrapper and
freed by `harness_loro_buffer_free`, including on errors. Rust panics are
caught before C; invalid non-null caller pointers are still caller UB.
The engine lock serializes document mutations and imports.

Zig's local projection is diffed onto retained maps, lists and `LoroText`
containers using the existing schema, not encoded into a new CRDT. Snapshots
and updates on chat2 are genuine Loro bytes. The chat2 checkpoint frontier
is **`oplog_vv().encode()`**, not `Frontiers.encode()` or JSON.

Ordinary snapshots omit causally parked imports in 1.13.9. Therefore:

- `NLR1` is a **private disk envelope**, never a wire document. It holds a
  Loro snapshot, raw unresolved incoming bytes, and the unsent local update
  frontier. It is atomically stored with the held applied cursor in one
  SQLite snapshot row. Raw pending imports and outgoing unacked batches
  are separate state.
- Restore imports the snapshot, replays retained incoming bytes, and holds
  the cursor until their actual prerequisites arrive. Contiguous transport
  rows may continue arriving while the applied cursor stays held, allowing
  a prerequisite in a later row to repair an earlier dependent row.
- A local outgoing update is written into the durable outbox before the
  unsent frontier is cleared. A crash at that boundary may duplicate Loro
  operations, not lose them; stable batch IDs and Loro imports are idempotent.
- ACKs never jump unread remote gaps. Checkpoints never cover unresolved
  imports, unacknowledged updates or unsent local edits.

Existing `HZD1` profiles are **not silently migrated or merged into a Loro
history**. Opening one in Loro mode returns `LegacySnapshotNeedsMigration`;
retain the original profile and use an explicitly isolated Loro profile.
No real user's data is needed by any acceptance check.

The native runtime uses chat2's existing HTTP rows/checkpoint transport;
the independent Rust peer uses retained `harness-sync::ChatClient` over a
real WebSocket with retained `harness-doc::SessionDoc` and SQLite snapshots.
Wire rules and shared vectors are unchanged. Native UI/history watchers
materialize the full document, not only the JSON tail.
