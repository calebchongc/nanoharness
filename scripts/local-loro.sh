#!/usr/bin/env bash
# Native full-sync acceptance. Unlike prove-zig.sh's LEGACY/OFFLINE mode,
# this intentionally retains Rust's Loro implementation and requires Rust.
# Usage: scripts/local-loro.sh check [--keep] | build | up [--phone] | down | status
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cmd="${1:-check}"; shift || true
unset HARNESS_NANO_ENGINE_BIN
export HARNESS_NANO_NO_RELEASE_CHECK=1
export HARNESS_HEAVY_BUILD_LOCK="${HARNESS_HEAVY_BUILD_LOCK:-$root/../zigfull.lock}"
case "$cmd" in
  build|check|up)
    if [[ "${LOCAL_LORO_NO_BUILD:-}" != 1 ]]; then
      bash "$root/scripts/build-loro.sh"
      (cd "$root/apps/nano" && "$root/scripts/heavy-build.sh" zig build install -Dloro-lib="$root/target/nano-loro/debug/libharness_nano_loro.a")
      if [[ "$cmd" == check && "$(uname -s)" == Darwin && -d /Applications/Xcode.app ]]; then
        "$root/scripts/check-loro-swift.sh"
      fi
    fi
    if [[ "$cmd" == check ]]; then exec node "$root/scripts/local-edge/full-sync.mjs" "$@"; fi
    if [[ "$cmd" == up ]]; then LOCAL_EDGE_NO_BUILD=1 exec "$root/scripts/local-edge.sh" up "$@"; fi
    ;;
  down|status) exec "$root/scripts/local-edge.sh" "$cmd" "$@" ;;
  *) echo "usage: scripts/local-loro.sh build | check [--keep] | up [--phone] | down | status" >&2; exit 2 ;;
esac
