#!/usr/bin/env bash
# Native full-sync acceptance. Unlike prove-zig.sh's LEGACY/OFFLINE mode,
# this retains a prebuilt Rust/Loro dylib. Producers/check peers need Rust;
# build/up can consume HARNESS_LORO_PREBUILT without Cargo or Rust installed.
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
      command -v node >/dev/null || { echo "Node 22+ is required" >&2; exit 1; }
      [[ "$(node -p 'Number(process.versions.node.split(".")[0])')" -ge 22 ]] || { echo "Node 22+ is required" >&2; exit 1; }
      if [[ ! -x "$root/edge/node_modules/.bin/wrangler" ]]; then
        (cd "$root/edge" && npm ci --no-audit --no-fund)
      fi
      artifact="${HARNESS_LORO_PREBUILT:-}"
      if [[ -z "$artifact" ]]; then
        bash "$root/scripts/build-loro.sh"
        artifact="$root/target/nano-loro/prebuilt/macos-$(uname -m)/libharness_nano_loro.dylib"
      fi
      [[ "$artifact" == /* && -f "$artifact" ]] || { echo "HARNESS_LORO_PREBUILT must name a trusted absolute dylib file" >&2; exit 1; }
      (cd "$root/apps/nano" && "$root/scripts/heavy-build.sh" zig build install -Dloro-dylib="$artifact")
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
