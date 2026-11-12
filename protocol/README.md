# chat2 sync protocol vectors

`chat2-vectors.json` pins the parts of the chat2 sync protocol that every implementation has to agree on, as data.
Each implementation runs its own test against this one file, so none can drift without a test failing.

| Implementation | Side | Runner | Run it |
| --- | --- | --- | --- |
| Rust (`crates/sync`) | client (desktop, engine, Android core) | `crates/sync/tests/chat2_vectors.rs` | `cargo test -p harness-sync --test chat2_vectors` |
| Zig (`apps/nano`) | client & engine (`chat2_wire.zig`) | `apps/nano/src/chat2_wire.zig` | `cd apps/nano && zig build test -Dtest-filter="chat2 vectors"` |
| Swift (`apps/ios/Harness/Sync`) | client (iOS) | `apps/ios/HarnessTests/Chat2VectorTests.swift` | `xcodebuild … -only-testing:HarnessTests/Chat2VectorTests test` |
| TypeScript (`edge/src/chat-frames.ts`) | server | `edge/src/chat-frames.vectors.test.ts` | `cd edge && npx vitest run src/chat-frames.vectors.test.ts` |

CI runs all three: `ui-tests.yml` (Rust), `parity.yml` (Swift) and `preview-tests.yml` (edge).

## What the file pins

- **`frameTypes`, `maxHeaderBytes`:** the frame type bytes and the header size cap.
- **`encode`:** exact bytes for a frame, `[type u8][headerLen u32 LE][header JSON][payload]`. Header JSON is compact,
  with keys in sorted order and no escaped `/`.
- **`decodeRejects`, `decodeAccepts`:** inputs a decoder must reject, and frames it must read back. A case marked
  `clientOnly` is accepted by clients, which skip unknown frame types, and rejected by the server.
- **`catchUp`:** the catch-up plan from a hello's state answer (`plan_catch_up` / `chatPlanCatchUp`).
- **`rowCursor`:** the contiguity rule for each row (`next_row_cursor` / `chatNextRowCursor`). For every incoming
  seq it gives the cursor afterwards, and whether the row was a gap. An implementation may import a contiguous run of
  rows in one batch, as iOS does, as long as these per-row cursors come out the same.

## Porting to a new language

1. Implement the codec, `plan_catch_up` and the row rule as pure functions. Keep them separate from I/O, so they can
   be called directly.
2. Add a runner that reads `protocol/chat2-vectors.json` from the repository at test time; don't copy it. Check every
   section that applies to your side, and fail on unknown plan names.
3. Add the runner to this table and to CI.

## Changing a rule

Change the vector, then every runner it breaks, in the same pull request. The expected values describe the protocol,
not any one implementation.

## Not covered

- Loro document behavior: what an import does to the doc, and how much it costs.
- Socket and HTTP transport timing: liveness, probes, backoff.
- Server storage: checkpoint trimming, seq assignment.
- Header fields beyond the ones above.

The Rust client also holds the cursor when a row's import reports missing causal dependencies, and asks for a
checkpoint. The Swift client doesn't check the import result for that, so the rule isn't pinned here yet.

# Device-room relay frame vectors

`device-frame-vectors.json` pins the device relay's frame codec: `uleb128(header length) ‖ UTF-8 JSON header ‖
payload`, header `{s, k, to?, from?}`, spoken by a host engine, a client link and the edge's `DeviceRoom`.

| Implementation | Side | Runner | Run it |
| --- | --- | --- | --- |
| Zig (`apps/nano/src/device_frame.zig`) | host relay | `apps/nano/src/device_frame.zig` | `cd apps/nano && zig build test -Dtest-filter="device frame vectors"` |
| TypeScript (`edge/src/device-room.ts`) | relay | `edge/src/device-frame.vectors.test.ts` | `cd edge && npx vitest run src/device-frame.vectors.test.ts` |

The Rust implementation (`crates/rpc/src/device_room.rs`) is frozen while the engine moves to Zig, so it has no
runner; the vectors were checked against its encoder's rules (`JSON.stringify` key order and escaping, which
`serde_json` matches for these inputs) and its unit tests' fixtures.

- **`kinds`, `relayErrors`:** frame kinds (the relay kind has a leading space) and relay control error codes.
- **`encode`:** exact bytes for a header and payload, including relay control, nudge, nudge ACK and echo frames.
- **`decodeRejects`, `decodeAccepts`:** inputs every decoder rejects or reads back. A case marked `typedOnly` is
  rejected by decoders that read a typed header (string `s` and `k`, valid UTF-8) and passed through by the relay,
  which treats the header as opaque.
- **`relayErrorCode`:** the code read from a relay control payload, or `null`.
- **`wsUrl`, `hostUrlSuffix`, `bearerFromQuery`:** the device-room socket URL, the host's `&nudgeAck=1`, and the
  dialer moving `token` from the query into an `Authorization: Bearer` header. Dialer rules; the relay skips them.

Not covered: socket timing (the 10 s ping, 25 s silence lease, reconnect backoff) and RPC payloads.
