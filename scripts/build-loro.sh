#!/usr/bin/env bash
# Explicit Rust dependency boundary for native Zig full-sync builds. This is
# project-owned C ABI code, not an official loro-ffi Zig/UniFFI binding.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
export CARGO_TARGET_DIR="$root/target/nano-loro"
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-4}"
"$root/scripts/heavy-build.sh" cargo build --manifest-path "$root/Cargo.toml" --locked -p harness-nano-loro --lib --examples
printf '%s\n' "$CARGO_TARGET_DIR/debug/libharness_nano_loro.a"
