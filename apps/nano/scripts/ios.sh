#!/bin/sh
# Builds the iOS app as zig-out/ios/Harness.app, from a clean checkout:
#
#   sh scripts/ios.sh sim                 # aarch64-ios-simulator, signed ad hoc
#   sh scripts/ios.sh install-sim         # the same, installed and launched with
#                                         # demo data on a booted Simulator
#   sh scripts/ios.sh device --adhoc      # aarch64-ios, a compile check signed ad hoc
#   sh scripts/ios.sh device --identity "<identity>" --profile <file>
#   sh scripts/ios.sh ipa --distribution --identity "<identity>" --profile <file> \
#       --build-number 42                 # zig-out/ios/Harness.ipa
#
# Signing comes from arguments or the environment, never from the repository:
#   --identity NAME      HARNESS_IOS_SIGN_IDENTITY   as `security find-identity` names it
#   --profile FILE       HARNESS_IOS_PROFILE         a .mobileprovision
#   --team ID            HARNESS_IOS_TEAM_ID         default: the team in testflight.yml
#   --distribution                                   App Store / TestFlight (production push)
#   --adhoc                                          device build that won't install
# And the bundle:
#   --bundle-id ID       HARNESS_IOS_BUNDLE_ID       default harness.codegraff.ios.nano
#   --build-number N     HARNESS_IOS_BUILD_NUMBER    CFBundleVersion
#   --udid UDID          HARNESS_IOS_SIM_UDID        install-sim's Simulator (default: booted)
#   --dry-run                                        print the zig build command, run nothing
# A device build with no identity stops with what to pass (src/ios_build_rules.zig).
#
# Further arguments go to `zig build` (another -Doptimize, --fork=..., -j1).
# Zig 0.17.0's std can't build for iOS as shipped (std.process.can_replace
# pulls in posix_spawn's /dev/null handling, "no field named 'fd' in
# NullFile"); nanoui's tools/ios/zig-lib.sh makes a patched lib folder and
# prints the --zig-lib flag for it (nothing, for a Zig whose std is fixed).
# The pinned nanoui's copy of that script is used, so the patch always
# matches the nanoui this app builds against.
set -eu
usage() {
    echo "usage: sh scripts/ios.sh sim|device|ipa|install-sim [--identity NAME] [--profile FILE] [--team ID]" >&2
    echo "       [--distribution] [--adhoc] [--bundle-id ID] [--build-number N] [--udid UDID] [--dry-run] [zig build arguments]" >&2
    exit 2
}
mode="${1:-}"
case "$mode" in
sim | install-sim) target=aarch64-ios-simulator ;;
device | ipa) target=aarch64-ios ;;
*) usage ;;
esac
shift

identity="${HARNESS_IOS_SIGN_IDENTITY:-}"
profile="${HARNESS_IOS_PROFILE:-}"
team="${HARNESS_IOS_TEAM_ID:-}"
bundle_id="${HARNESS_IOS_BUNDLE_ID:-}"
build_number="${HARNESS_IOS_BUILD_NUMBER:-}"
udid="${HARNESS_IOS_SIM_UDID:-booted}"
adhoc=false
distribution=false
dry_run=false
value() {
    [ $# -ge 2 ] || {
        echo "ios.sh: $1 needs a value" >&2
        exit 2
    }
}
while [ $# -gt 0 ]; do
    case "$1" in
    --identity) value "$@"; identity="$2"; shift 2 ;;
    --profile) value "$@"; profile="$2"; shift 2 ;;
    --team) value "$@"; team="$2"; shift 2 ;;
    --bundle-id) value "$@"; bundle_id="$2"; shift 2 ;;
    --build-number) value "$@"; build_number="$2"; shift 2 ;;
    --udid) value "$@"; udid="$2"; shift 2 ;;
    --adhoc) adhoc=true; shift ;;
    --distribution) distribution=true; shift ;;
    --dry-run) dry_run=true; shift ;;
    *) break ;;
    esac
done
# The profile as given, from where the script was run.
if [ -n "$profile" ]; then
    [ -f "$profile" ] || {
        echo "ios.sh: no provisioning profile at the path given" >&2
        exit 1
    }
    profile="$(cd "$(dirname "$profile")" && pwd)/$(basename "$profile")"
fi
cd "$(dirname "$0")/.."

# The zig build arguments, the script's own in front of the caller's.
[ "$mode" = ipa ] && set -- ipa "$@"
[ "$distribution" = true ] && set -- -Dios-distribution=true "$@"
[ "$adhoc" = true ] && set -- -Dios-adhoc=true "$@"
[ -n "$build_number" ] && set -- "-Dios-build-number=$build_number" "$@"
[ -n "$bundle_id" ] && set -- "-Dios-bundle-id=$bundle_id" "$@"
[ -n "$team" ] && set -- "-Dios-team=$team" "$@"
[ -n "$profile" ] && set -- "-Dios-profile=$profile" "$@"
[ -n "$identity" ] && set -- "-Dios-identity=$identity" "$@"
set -- --release=safe -Dtarget="$target" "$@"

if [ "$dry_run" = true ]; then
    printf 'zig build [--zig-lib-dir patched]'
    printf ' %s' "$@"
    printf '\n'
    exit 0
fi

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
if [ "$mode" != install-sim ]; then
    # shellcheck disable=SC2086 # lib_flag is one flag or nothing
    exec zig build $lib_flag "$@"
fi

# shellcheck disable=SC2086
zig build $lib_flag "$@"
app=zig-out/ios/Harness.app
id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")
if [ "$udid" = booted ] && ! xcrun simctl list devices booted | grep -q Booted; then
    echo "ios.sh: no simulator is booted: open -a Simulator, or xcrun simctl boot <device>" >&2
    exit 1
fi
xcrun simctl install "$udid" "$app"
# Demo data only: the app embeds its engine with a synthetic workspace.
SIMCTL_CHILD_HARNESS_MOBILE_DEMO=1 xcrun simctl launch --terminate-running-process "$udid" "$id" --demo
echo "ios.sh: launched $id with demo data"
