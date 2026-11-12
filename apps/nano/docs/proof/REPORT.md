# Zig-only proof

- Commit: `272468a1`
- Zig: 0.17.0
- Result: pass
- Tests (no crates/, Cargo.toml or Cargo.lock): 1509/1511 tests passed (2 skipped)
- Fake arms (RPC methods still answering canned data, src/fake_arm_gate.zig): 20

| Step | Result | Time |
|---|---|---|
| no-rust | pass | 7 s |
| tests-without-rust | pass | 208 s |
| bundle | pass | 2 s |
| bundle-contents | pass | 0 s |
| proof-repo | pass | 0 s |
| engine-up | pass | 0 s |
| engine-scenario | pass | 1 s |
| desktop-render | pass | 6 s |

## Engine scenario

The bundle's harness-engine, isolated (temporary HOME, data folder and port, auth off, previews on a free port):

```json
{"commandId": "m-proof-1", "git": {"additions": 1, "diffFiles": ["README.md"], "statusKeys": ["checkoutId", "complete", "deviceId", "files", "revision"]}, "seconds": 0.48, "terminal": {"echo": "proof-42"}, "transcript": {"messages": 2, "prompt": ["Say hello for the proof"], "replyHasMockText": true}, "turn": {"device": true, "status": "idle"}}
```

## Images

![The desktop app showing the proof chat](desktop-chat.png)

iOS simulator: skipped: a booted simulator holds the person's own Harness install, which the proof does not replace.
