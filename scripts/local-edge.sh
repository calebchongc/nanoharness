#!/usr/bin/env bash
# The Cloudflare edge Worker (edge/) run locally with `wrangler dev --local`,
# and the Zig harness-engine (apps/nano) against it. Nothing leaves this
# machine: no Cloudflare account, no deployed edge, made-up identities.
#
#   scripts/local-edge.sh check [--repeat N] [--proof] [--keep]
#       End-to-end proof: one line per step (pass, fail or skipped, time,
#       reason); exits 1 when a step fails. --proof rewrites the run table in
#       apps/nano/docs/proof/LOCAL-EDGE.md.
#   scripts/local-edge.sh up [--phone] [--ttl-minutes N]
#       Leaves the local edge, a signed-in engine with a seeded chat and the
#       harness-nano window running (--phone: a second device in the phone
#       layout too). Stopped by `down`, or after N minutes (default 120).
#   scripts/local-edge.sh down | status
#
# Needs Node 20+ and edge/node_modules (`npm ci` in edge/, run here once if
# missing); builds harness-engine and harness-nano with `zig build` unless
# LOCAL_EDGE_NO_BUILD=1. Heavy builds go through scripts/heavy-build.sh.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cmd="${1:-}"

# The installed app's engine must never be picked up by anything started here.
unset HARNESS_NANO_ENGINE_BIN HARNESS_IPC_PORT HARNESS_DATA_DIR HARNESS_EDGE_URL HARNESS_EDGE_TOKEN

command -v node >/dev/null || { echo "local-edge: node is required (20 or newer)" >&2; exit 1; }
node_major="$(node -p 'process.versions.node.split(".")[0]')"
if [ "$node_major" -lt 20 ]; then echo "local-edge: node 20 or newer is required (found $(node --version))" >&2; exit 1; fi

case "$cmd" in
  check|up)
    if [ ! -x "$root/edge/node_modules/.bin/wrangler" ]; then
      echo "local-edge: installing the edge's locked dependencies (npm ci in edge/)"
      (cd "$root/edge" && npm ci --no-audit --no-fund)
    fi
    if [ "${LOCAL_EDGE_NO_BUILD:-}" != "1" ]; then
      echo "local-edge: zig build (harness-engine, harness-nano)"
      (cd "$root/apps/nano" && "$root/scripts/heavy-build.sh" zig build install)
    fi
    ;;
esac

exec node "$root/scripts/local-edge/main.mjs" "$@"
