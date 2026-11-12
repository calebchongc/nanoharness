#!/usr/bin/env bash
# Arch Linux packaging: produce
#   target/package/harness-<version>-linux-<arch>.pkg.tar.zst
# via a pinned nfpm (scripts/install-nfpm.sh).
#
# Ships only Zig output: /usr/bin/harness-nano (the app) and
# /usr/bin/harness-engine (the engine). Reuses the binaries package-linux.sh
# already built in apps/nano/zig-out; builds only if missing.
#
# Usage: scripts/package-arch.sh
# Env:   PROFILE=debug builds Debug if a build is needed; otherwise ReleaseSafe.
#        BIN_DIR=<dir> holding harness-nano and harness-engine (dry-run/testing).
#        NFPM_ARCH=amd64|arm64 override the package arch (default: uname -m).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="${PROFILE:-dist}"
VERSION="$(sed -n 's/^[[:space:]]*\.version[[:space:]]*=[[:space:]]*"\([0-9][0-9.]*\)",[[:space:]]*$/\1/p' "$ROOT/apps/nano/build.zig.zon" | head -n 1)"
[[ -n "$VERSION" ]] || { echo "error: no .version in apps/nano/build.zig.zon" >&2; exit 1; }
OUT_DIR="$ROOT/target/package"
PKG="$OUT_DIR/harness-$VERSION-linux-$(uname -m).pkg.tar.zst"

cd "$ROOT"
BIN_DIR="${BIN_DIR:-$ROOT/apps/nano/zig-out/bin}"
if [[ ! -x "$BIN_DIR/harness-nano" || ! -x "$BIN_DIR/harness-engine" ]]; then
  if [[ "$PROFILE" == "debug" ]]; then OPTIMIZE=Debug; else OPTIMIZE=ReleaseSafe; fi
  (cd "$ROOT/apps/nano" && "$ROOT/scripts/heavy-build.sh" zig build -Doptimize="$OPTIMIZE")
  BIN_DIR="$ROOT/apps/nano/zig-out/bin"
fi

# pacman arch names: x86_64 / aarch64. nfpm takes amd64 / arm64.
case "$(uname -m)" in
  x86_64)  NFPM_ARCH="${NFPM_ARCH:-amd64}" ;;
  aarch64|arm64) NFPM_ARCH="${NFPM_ARCH:-arm64}" ;;
  *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac

TOOLS="$OUT_DIR/.tools"
if [[ ! -x "$TOOLS/nfpm" ]]; then
  "$ROOT/scripts/install-nfpm.sh" "$TOOLS" >/dev/null
fi

# nfpm does not expand env vars inside contents entries — render the config.
config="$(mktemp)"
desktop="$(mktemp)"
trap 'rm -f "$config" "$desktop"' EXIT
# The desktop entry opens the Zig app (the template still names the old binary).
sed -e 's/^Exec=harness /Exec=harness-nano /' -e 's/^TryExec=harness$/TryExec=harness-nano/' \
  "$ROOT/dist/harness.desktop" >"$desktop"
cat >"$config" <<YAML
name: harness
arch: $NFPM_ARCH
platform: linux
version: "$VERSION"
release: "1"
maintainer: Harness maintainers
homepage: https://github.com/justrach/harness
description: One native workspace for your coding agents
license: custom

depends:
  - glibc
  - gcc-libs
  - libxcb
  - libxkbcommon
  - libxkbcommon-x11
  - wayland
  - libglvnd
  - vulkan-icd-loader
  - gtk3
  - webkit2gtk-4.1
  - json-glib

contents:
  - src: $BIN_DIR/harness-nano
    dst: /usr/bin/harness-nano
    file_info:
      mode: 0755
  - src: $BIN_DIR/harness-engine
    dst: /usr/bin/harness-engine
    file_info:
      mode: 0755
  - src: $desktop
    dst: /usr/share/applications/harness.desktop
    file_info:
      mode: 0644
  - src: $ROOT/dist/harness.png
    dst: /usr/share/icons/hicolor/1024x1024/apps/harness.png
  - src: $ROOT/dist/harness.svg
    dst: /usr/share/icons/hicolor/scalable/apps/harness.svg
  - src: $ROOT/LICENSE
    dst: /usr/share/licenses/harness/LICENSE
  - src: $ROOT/THIRD_PARTY_NOTICES.md
    dst: /usr/share/licenses/harness/THIRD_PARTY_NOTICES.md
  - src: $ROOT/third_party/licenses/Zeron-MIT.txt
    dst: /usr/share/licenses/harness/Zeron-MIT.txt
  - src: $ROOT/third_party/licenses/CodeGraff-LICENSE.txt
    dst: /usr/share/licenses/harness/CodeGraff-LICENSE.txt
YAML
for f in "$ROOT"/apps/nano/assets/fonts/licenses/*; do
  printf '  - src: %s\n    dst: /usr/share/licenses/harness/fonts/%s\n' \
    "$f" "$(basename "$f")" >>"$config"
done

mkdir -p "$OUT_DIR"
rm -f "$PKG"
"$TOOLS/nfpm" package --config "$config" \
  --packager archlinux --target "$PKG"

echo "packaged: $PKG"
