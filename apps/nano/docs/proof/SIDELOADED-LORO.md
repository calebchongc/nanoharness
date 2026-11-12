# Temporary sideloaded Rust/Loro library (macOS)

The native Zig app/engine can load **`libharness_nano_loro.dylib`**, a
separately built Rust `cdylib`. This is neither pure Zig nor a second engine
process. It retains the project-owned C ABI, `harness-doc` schema and locked
Loro 1.13.9. It is not an official upstream `loro-ffi` Zig binding.

## Artifact and loading contract

- `scripts/build-loro.sh` is the **producer**: it requires Cargo/Rust and
  builds the retained peer used by acceptance too. It writes the dylib to
  `target/nano-loro/prebuilt/macos-<architecture>/`. Rust source/home paths
  are remapped; debug/local symbols are stripped from this copied artifact;
  its Mach-O identity is `@rpath/libharness_nano_loro.dylib` and it is ad-hoc
  signed. The original static archive/rlib remain available for developer tests.
- `zig build install -Dloro-dylib=/trusted/absolute/artifact.dylib` only
  consumes/copies the prebuilt artifact. It never runs Cargo or downloads a
  bridge. Its installed name is `zig-out/bin/libharness_nano_loro.dylib`.
  No producer path is compiled into the app or engine.
- At startup both app and engine validate the library **before opening a
  profile/window/socket**. The default is the constant filename beside the
  canonical executable: either the installed `bin/` directory or
  `Contents/MacOS/` in the app. Relocating the complete directory/app works.
- `HARNESS_NANO_LORO_LIBRARY` is an explicit **trusted absolute path** override
  for development. Blank/relative values fail. An invalid override never
  falls back to the bundled file, cwd, original build tree or ambient paths.
  Dyld path/substitution variables are rejected. This is not a sandbox against
  malicious code already injected before `main`; selecting a library trusts
  its executable code, not just the handshake.
- `harness_loro_abi_version()` must return **1** and
  `harness_loro_capabilities()` must include **0x3f** (retained schema,
  snapshot/update import, binary VV, pending-import retention, atomic private
  persistence and commands). All four handle/buffer symbols must exist.
  Validation precedes any document creation. Missing file, relative path,
  wrong architecture, invalid binary, missing symbol, ABI mismatch and missing
  capabilities have explicit errors. There is no automatic HZD1 fallback.
- A document owns a `dlopen` reference. Rust handles and return buffers are
  freed by that same library before its reference closes. Closing another
  document does not invalidate a live one. Calls remain serialized per doc;
  Rust panics do not unwind across C. Ownership/error rules are unchanged.

Pure/default builds remain legacy/offline HZD1. Explicit `-Dloro-lib=<archive>`
remains a static developer mode. Static and dynamic options are mutually
exclusive. `no-rust` still passes only for pure mode and refuses both retained
Rust modes; not needing the toolchain at runtime does not make the artifact
all-Zig. Existing HZD1 histories are not migrated.

## Build and run

From the repository root, with Zig 0.17.0 and macOS developer tools:

```sh
export HARNESS_HEAVY_BUILD_LOCK="$(pwd)/../zigfull.lock"
# Artifact producer only (requires Rust):
scripts/build-loro.sh

# Consumer can receive this artifact separately; no Cargo/Rust needed:
export HARNESS_LORO_PREBUILT="$(pwd)/target/nano-loro/prebuilt/macos-$(uname -m)/libharness_nano_loro.dylib"
scripts/local-loro.sh build
scripts/local-loro.sh up --phone --no-app
scripts/local-loro.sh status
scripts/local-loro.sh down

# Developer acceptance also needs the retained Rust peer + pinned Swift runner:
scripts/local-loro.sh check --keep

# Ad-hoc app bundle, consumes only the prebuilt library:
scripts/heavy-build.sh sh apps/nano/scripts/bundle.sh \
  -Dloro-dylib="$HARNESS_LORO_PREBUILT"
python3 scripts/test-loro-dylib.py "apps/nano/zig-out/Harness Nano.app"
# Rebuild without Rust tools on PATH; test a renamed bundle from another cwd;
# run all ten real full-sync stages using that relocated bundle:
scripts/check-loro-dylib.sh --keep
```

`up` still needs Node 22+ and the local Worker's installed dependencies.
`HARNESS_LORO_PREBUILT` skips the producer, not the Worker's dependencies.
`check` is a developer proof, not a promise that its Rust/Swift fixture
executables are part of the user app. Profiles, ports, identities and sessions
are synthetic; release checks are disabled; no installed-engine override is
used. The runner's bounded watchdog/down command owns only its own processes.

The production `scripts/package-macos.sh` accepts the same
`HARNESS_LORO_PREBUILT` and signs that copy with the selected identity before
signing the executables/app. That script's unrelated CLI downloads,
Developer ID signing, notarization and upload paths are not exercised by this
local test. No library-validation bypass is added. Public distribution needs
a matching architecture and same-team signing/notarization, not just our
local ad-hoc signature. Only macOS arm64 is validated here; no universal,
iOS, Linux or Windows dynamic-loader claim is made.

## Verification

### Before / after

On `03cf6c99`, the new bounded `scripts/test-loro-dylib.py` missing-library
regression failed: the existing statically linked engine ignored the requested
runtime library and remained running past the five-second rejection deadline.
The regression terminated its own synthetic engine. With dynamic mode, the
same case exits with `LoroLibraryMissing` before creating the data directory.

The expanded rejection suite also covers a relative/blank path, dyld ambient
substitution, ABI 2, missing capabilities, missing call symbol, opposite
architecture and invalid Mach-O bytes. Each must fail before profile creation;
a valid bundled library must not rescue an invalid explicit override. Both app
and engine are tested with their bundled dylib absent, before any UI launch.
The focused document suite additionally closes one loaded document while
continuing to use another, and checks constructor-error allocation cleanup.

The first strict package check exposed a stale retired executable/signature in
the reused generated bundle. Packaging now recreates that bundle's generated
`Contents` before copying/signing current artifacts; it does not alter any
installed app or user profile. Initial format checks also found pre-existing
indentation differences in `engine_host.zig`'s interrupt block, identical to
`03cf6c99`; those unrelated lines are left unchanged.

### Final runs

Tested implementation commit: **`7f9c9d2f`**, macOS arm64. The proof commit
changes documentation only. Producer uses the Cargo development profile;
Zig bundle uses ReleaseSafe. No performance/release-size claim is made.

Command: `HARNESS_HEAVY_BUILD_LOCK="$(pwd)/../zigfull.lock" HARNESS_LORO_PREBUILT="$(pwd)/target/nano-loro/prebuilt/macos-$(uname -m)/libharness_nano_loro.dylib" scripts/check-loro-dylib.sh --keep`.

The reusable check built the ad-hoc app with Cargo/rustc/rustup absent from
PATH, verified its nested signatures, copied it to a renamed temporary app,
changed cwd to `/`, and ran `scripts/local-loro.sh check` against its own
packaged engine/dylib with the same toolchain-free PATH. Both Zig devices used
the relocated artifact. All ten stages passed, **none skipped**:

| Stage | Result | Seconds | Evidence |
|---|---|---:|---|
| loopback Worker + explicit retained-Loro Zig engine | pass | 2.13 | `{"realLoro":true,"dynamicLibrary":true}` |
| retained Rust binary doc -> Worker rows -> native full history | pass | 5.8 | `{"seeded":131,"dependentBeforePrerequisite":true,"pendingPersistedAcrossRestart":true,"appliedCursorHeld":0,"headSeq":2,"messages":131}` |
| Zig turn -> retained Rust ChatClient typed document | pass | 0.84 | `{"messages":133,"nativeUnicodeRoundtrip":true,"pendingPushes":0,"remoteRunCount":0}` |
| Rust document command executes once on Zig host and returns via Loro | pass | 2.81 | `{"messages":135,"nativeUnicodeRoundtrip":true,"pendingPushes":0,"remoteRunCount":1}` |
| second Zig device reads >64 messages from document, not tail | pass | 0.68 | `{"messages":135}` |
| offline concurrent Rust/Zig updates survive process and Worker restart | pass | 4.2 | `{"offlineBytes":293,"pendingPushes":1,"messagesAfterRestart":137,"stableDuplicateSeq":6,"remoteCommandCount":1}` |
| host checkpoint trims log; fresh Rust and cold Zig catch up below floor | pass | 10.16 | `{"headSeq":11,"checkpointSeq":9,"seqFloor":9,"freshRustCheckpoint":true,"coldZigMessages":137}` |
| pinned Swift core reads native/Rust schema and sends a real Loro update | pass | 3.82 | `{"swiftPackage":"1.13.3","typedFields":true,"binaryVV":true,"messages":137,"emittedRealUpdate":true,"updateSeq":12,"appliedByRustAndZig":true}` |
| independent typed projections + mutual VV convergence | pass | 0.84 | `{"messages":137,"mutualVV":true,"swiftUpdateApplied":true,"typedConverged":true,"zigCursor":12}` |
| cleanup | pass | — | `{}` |

Artifact fingerprint (the separately produced/prebuilt copy):

- Bytes: **5904512**.
- SHA-256: `cc0aa5414d566d758cf52a1143b1eb59ff5baccbbdf6cb2ecc5298e36e81ff8e`.

Additional checks:

- `python3 scripts/test-loro-dylib.py "apps/nano/zig-out/Harness Nano.app"`:
  nine configuration/library rejection cases, two missing-bundled-library
  entry-point cases, and invalid explicit override despite valid bundle all
  passed. Every rejection preceded profile creation. Ad-hoc nested/outer
  signatures passed strict/deep verification before and after relocation.
- Mach-O checks passed: safe install ID, only system dynamic dependencies,
  no unresolved static `harness_loro_*` imports in the Zig binaries, and no
  producer checkout/home path embedded in the library or release executables.
- Dynamic focused suite against the remapped, stripped artifact:
  `zig build test -Dloro-dylib="$HARNESS_LORO_PREBUILT" -Dtest-filter='retained Loro' --summary all`:
  **24/24 passed**, including lifetime and constructor cleanup.
- Static focused suite, `-Dloro-lib=.../debug/libharness_nano_loro.a`:
  **24/24 passed**. Pure focused suite: **21 passed, 3 skipped** (24 total).
  This change does not claim a fresh full 1,500-test pure-mode run.
- `cargo test --locked -p harness-nano-loro --lib`: **2/2 passed**.
  Existing `harness-sync` unnecessary-unsafe/dead-code warnings remain.
- `zig build no-rust` passed; dynamic retained mode was explicitly refused
  with “not an all-Zig build”. No scanner exemption was introduced.
- `LOCAL_LORO_NO_BUILD=1 scripts/local-loro.sh up --phone --no-app --ttl-minutes 3`,
  status, down, status: passed on fresh temporary profiles/pointer; four owned
  process groups stopped, state removed, final status “nothing is up”.
- `LOCAL_EDGE_NO_BUILD=1 scripts/local-edge.sh check`: **9/9 stages passed**
  against the dynamic engine, including missing/forged/stale session rejection,
  protected registry 401 / own-org 200 / cross-org 403, forged engine startup
  refusal, A/B relay and persisted restart. Three owned groups and 15 observed
  ports were closed. The old automatic tool-sidecar path remains skipped
  because no turn produces one; retrieval of a Worker-held blob was exercised.
- Touched Rust format check passed with child traversal disabled. Zig format
  checks passed except the unchanged baseline interrupt-block indentation
  noted above; a baseline/current comparison confirmed identical formatting
  differences. Shell/Python/Node syntax checks passed.

The actual packaged **headless engine** was positively exercised through the
relocated app; both app/engine startup rejection paths were exercised. This is
not a positive native-window/iOS UI transport test. Swift's pinned core reads
and emits genuine document updates in the acceptance run; its app network
stack is not exercised. Existing full-sync limitations in `FULL-LORO.md`
(history reset materialization, HTTP/coalescing, large-update splitting,
legacy migration and unimplemented sidecar/UI paths) remain unchanged.
Developer ID/notarization, universal binaries and other platforms remain
unverified. No real profile, production deploy, remote write, PR or push was
used; all check-owned processes and relocated copies were cleaned up.
