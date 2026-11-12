#!/bin/sh
# Builds the iOS app as zig-out/ios/Harness.app, from a clean checkout:
#
#   sh scripts/ios.sh sim      # aarch64-ios-simulator
#   sh scripts/ios.sh device   # aarch64-ios
#
# Further arguments go to `zig build` (another -Doptimize, --fork=..., -j1).
# Zig 0.17.0's std can't build for iOS as shipped (std.process.can_replace
# pulls in posix_spawn's /dev/null handling, "no field named 'fd' in
# NullFile"); nanoui's tools/ios/zig-lib.sh makes a patched lib folder and
# prints the --zig-lib flag for it (nothing, for a Zig whose std is fixed).
# The pinned nanoui's copy of that script is used, so the patch always
# matches the nanoui this app builds against.
set -eu
cd "$(dirname "$0")/.."
case "${1:-}" in
sim) target=aarch64-ios-simulator ;;
device) target=aarch64-ios ;;
*)
    echo "usage: sh scripts/ios.sh sim|device [zig build arguments]" >&2
    exit 2
    ;;
esac
shift
# The pinned nanoui, fetched into zig-pkg/ like every dependency.
zig build --fetch
hash=$(sed -n 's/^[[:space:]]*\.hash[[:space:]]*=[[:space:]]*"\(nanoui-[^"]*\)",[[:space:]]*$/\1/p' build.zig.zon | head -n 1)
if [ -z "$hash" ]; then
    echo "ios.sh: no nanoui dependency hash in build.zig.zon" >&2
    exit 1
fi
zig_lib_sh="zig-pkg/$hash/tools/ios/zig-lib.sh"
if [ ! -f "$zig_lib_sh" ]; then
    echo "ios.sh: $zig_lib_sh is missing after zig build --fetch" >&2
    exit 1
fi
lib_flag=$(sh "$zig_lib_sh")
# shellcheck disable=SC2086 # lib_flag is one flag or nothing
exec zig build $lib_flag --release=safe -Dtarget="$target" "$@"
