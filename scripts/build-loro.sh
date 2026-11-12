#!/usr/bin/env bash
# Explicit Rust dependency boundary for native Zig full-sync builds. This is
# project-owned C ABI code, not an official loro-ffi Zig/UniFFI binding.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
export CARGO_TARGET_DIR="$root/target/nano-loro"
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-4}"
# Rust panic/source metadata must not ship checkout or home paths. Cargo's
# encoded form preserves remap arguments when a trusted checkout has spaces.
if [[ -n "${CARGO_ENCODED_RUSTFLAGS:-}" ]]; then
  IFS=$'\x1f' read -r -a flags <<< "$CARGO_ENCODED_RUSTFLAGS"
else
  read -r -a flags <<< "${RUSTFLAGS:-}"
fi
flags+=("--remap-path-prefix=$HOME=/build-home" "--remap-path-prefix=${CARGO_HOME:-$HOME/.cargo}=/cargo" "--remap-path-prefix=$root=/harness")
printf -v CARGO_ENCODED_RUSTFLAGS '%s\x1f' "${flags[@]}"
export CARGO_ENCODED_RUSTFLAGS="${CARGO_ENCODED_RUSTFLAGS%$'\x1f'}"
"$root/scripts/heavy-build.sh" cargo build --manifest-path "$root/Cargo.toml" --locked -p harness-nano-loro --lib --examples
[[ "$(uname -s)" == Darwin ]] || { echo "sideloaded Loro supports macOS only" >&2; exit 1; }
artifact_dir="$CARGO_TARGET_DIR/prebuilt/macos-$(uname -m)"
mkdir -p "$artifact_dir"
cp "$CARGO_TARGET_DIR/debug/libharness_nano_loro.dylib" "$artifact_dir/"
artifact="$artifact_dir/libharness_nano_loro.dylib"
# No absolute Cargo build directory in a distributable's Mach-O identity.
install_name_tool -id '@rpath/libharness_nano_loro.dylib' "$artifact"
strip -S -x "$artifact"
codesign --force --sign - "$artifact"
printf '%s\n' "$artifact"
