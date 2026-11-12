#!/usr/bin/env bash
# Developer proof for a separately produced dylib. The Rust/Swift acceptance
# peers and local Worker dependencies must already be built/installed.
# Usage: HARNESS_LORO_PREBUILT=/trusted/absolute/lib.dylib bash scripts/check-loro-dylib.sh [--keep]
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
artifact="${HARNESS_LORO_PREBUILT:?supply the trusted absolute prebuilt dylib}"
[[ "$artifact" == /* && -f "$artifact" ]] || { echo "prebuilt dylib must be an absolute existing file" >&2; exit 1; }
export HARNESS_HEAVY_BUILD_LOCK="${HARNESS_HEAVY_BUILD_LOCK:-$root/../zigfull.lock}"
tools="$(mktemp -d "${TMPDIR:-/tmp}/nano-dylib-tools.XXXXXX")"
relocated="$(mktemp -d "${TMPDIR:-/tmp}/nano-relocatable.XXXXXX")"
trap 'rm -rf "$tools" "$relocated"' EXIT
ln -s "$(command -v zig)" "$tools/zig"
ln -s "$(command -v node)" "$tools/node"
consumer_path="$tools:/usr/bin:/bin:/usr/sbin:/sbin"
env PATH="$consumer_path" /bin/sh -c 'if command -v cargo || command -v rustc || command -v rustup; then exit 1; fi'
echo "PASS consumer build/runtime PATH contains no Cargo, rustc or rustup"
env PATH="$consumer_path" "$root/scripts/heavy-build.sh" sh "$root/apps/nano/scripts/bundle.sh" -Dloro-dylib="$artifact"
LORO_TEST_ENGINE="$root/apps/nano/zig-out/Harness Nano.app/Contents/MacOS/harness-engine"
export LORO_TEST_ENGINE
python3 "$root/scripts/test-loro-dylib.py" "$root/apps/nano/zig-out/Harness Nano.app"
cp -R "$root/apps/nano/zig-out/Harness Nano.app" "$relocated/Renamed Nano.app"
# A different cwd and a renamed bundle must not use the original build path.
cd /
unset HARNESS_NANO_ENGINE_BIN
export PATH="$consumer_path"
LOCAL_LORO_BIN_DIR="$relocated/Renamed Nano.app/Contents/MacOS" \
LOCAL_LORO_NO_BUILD=1 HARNESS_NANO_NO_RELEASE_CHECK=1 \
  "$root/scripts/local-loro.sh" check "$@"
