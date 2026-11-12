# Live retained-Loro iOS Simulator demo

This is the native **iOS Simulator** app, not desktop `--mobile`, and not
`--demo`'s disconnected synthetic fixture. Verified on an arm64 iPhone 18 Pro
simulator running iOS 27.2. Its separate bundle identifier is
`harness.codegraff.ios.nano.localsync-adaptation`; it does not replace either
`harness.codegraff.ios` or `harness.codegraff.ios.nano`, and no simulator is erased.

## Platform boundary

The desktop `libharness_nano_loro.dylib` is macOS-only and is NOT installed
on iOS. This simulator-only adaptation builds the same project-owned C ABI,
retained `harness-doc` schema and locked Loro 1.13.9 as an
**`aarch64-apple-ios-sim` static archive**, then links that archive into the
Zig `aarch64-ios-simulator` app. The installed executable's Mach-O build
platform is **7 (iOS Simulator)**, architecture arm64. The physical-iOS binary
that happened to be in the old output directory (platform 2) was not installed.
No physical-device signing/account change or deployment was performed.

The embedded host now shares the existing verified local-session resolver:
explicit opt-in, literal loopback URL, real local Worker session verification,
and no fallback from a failed local configuration into production auth.
Physical iOS rejects this local mode. Normal production configuration remains
the default. Local mode cannot be combined with the offline fixture flag.
The embedded background worker runs genuine chat2 Loro sync and persists
snapshots/cursors in this separate app's own SQLite container.

## Build / launch / stop

From the repository root, with the selected Xcode and Rust simulator target
installed:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export HARNESS_HEAVY_BUILD_LOCK="$(pwd)/../zigfull.lock"
export CARGO_TARGET_DIR="$(pwd)/target/nano-loro-simulator"
export CARGO_BUILD_JOBS=4
scripts/heavy-build.sh cargo build --locked -p harness-nano-loro --lib \
  --target aarch64-apple-ios-sim
scripts/heavy-build.sh sh apps/nano/scripts/ios.sh sim \
  --bundle-id harness.codegraff.ios.nano.localsync-adaptation \
  -Dloro-lib="$CARGO_TARGET_DIR/aarch64-apple-ios-sim/debug/libharness_nano_loro.a"

# Explicitly choose an available iOS Simulator, never a physical device:
export HARNESS_IOS_SIM_UDID=<selected-simulator-udid>
node scripts/local-loro-simulator.mjs up
node scripts/local-loro-simulator.mjs check
node scripts/local-loro-simulator.mjs status
node scripts/local-loro-simulator.mjs down
```

The local macOS backend/binaries and its prebuilt macOS dylib must already be
built (`scripts/local-loro.sh build`); the simulator launcher reuses those,
never an installed personal engine. It starts a synthetic loopback Worker and
host engine with release checks off, verifies simulator platform/bundle ID,
and installs only the isolated identifier. An existing installation without
this demo's ownership record is refused. Session values are passed from the
runner's temporary state through `SIMCTL_CHILD_` environment, never hardcoded,
printed or put in launch arguments. The app uses a separate simulator
container, not a real profile. Setup is explicitly skipped for this synthetic
launch, not globally disabled in app code.

The backend has a **120-minute TTL**. A watchdog terminates this app shortly
before the backend expires; `down` stops only this app and this run's owned
backend, preserving the simulator and its other apps/data. Runtime details are
in ignored `target/nano-simulator-demo/config.json`; session material stays in
the temporary local-edge state. The requested live demo is intentionally left
running after verification.

## Before / after evidence

- Before the build fix, the actual simulator build failed with six undefined
  `_harness_loro_*` symbols: iOS returned before the desktop archive-link loop.
  The corrected simulator branch links its own archive before bundling. The
  same build command then passed and the resulting app ran on the simulator.
- Before the auth fix, `embedded local auth: invalid local session fails before
  server startup` failed with `InvalidLocalSessionWasIgnored` (18 passed,
  1 failed). It now fails closed. Embedded-auth focused suite: **20/20 passed**,
  including implicit bearer, production-default/remote origin rejection, and
  offline-fixture/local-auth conflict checks.
- Existing local auth suite: **24/24 passed**. Pure `no-rust` gate passed;
  retained simulator mode is explicitly Rust-dependent. Touched Zig formatting,
  Node syntax and diff-whitespace checks passed.

## Actual local transport result

`node scripts/local-loro-simulator.mjs check` passed with a unique prompt,
waiting for a completed assistant result on both the host and simulator:

- `EngineInfo`: retained Loro enabled, dynamic loading false (static archive),
  development scope; `AuthStatus`: verified signed-in local session.
- Simulator queue mutation reached the real Worker and independent host;
  Worker sequence advanced **7 -> 8** on that mutation.
- Host document mutation reached the simulator through actual Loro sync.
- The app was terminated and relaunched with the same isolated container;
  both document changes and the synced transcript were present afterwards.
- A unique prompt submitted through the simulator executed on the host and
  its completed reply returned to the simulator. Final observed head was **10**.
- The simulator's own SQLite snapshot contained private **NLR1** persistence
  and a nonzero durable cursor (**10**), not HZD1 or tail-only state.
- `target/nano-simulator-demo/result.json` records the scalar outcome;
  `target/nano-simulator-demo/live-sync-final.png` captures only the synthetic
  app viewport. The native runtime UI snapshot also exposed the expected chat
  title, synced text and composer/model controls. The notification permission
  prompt was dismissed only for this isolated app.

## Viewer and remaining limits

The app is confirmed rendering on the actual simulator. This Xcode installation
has no `Simulator.app`, so `open -a Simulator` and the conventional developer
path cannot foreground a separate Simulator window. The launcher therefore
leaves the app running and instructs selection of the booted iPhone in
**Harness Device Manager**. Opening/foregrounding that manager was not verified
by this worker: nanocua lacks Accessibility permission and the shell AX tree
exposes no usable Harness controls. A simulator screenshot must not be called
a screenshot of an opened Device Manager window.

This is functional live document-sync evidence, not a mobile visual-parity
claim. The captured UI has existing safe-area/header overlap and some code
line clipping; those unrelated layout issues are not changed here. The model
uses the synthetic `mock` harness, not a real provider or production account.
Full production auth, physical devices, Developer ID/App Store signing,
mobile performance and every UI/attachment path are not covered by this run.
