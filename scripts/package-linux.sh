#!/usr/bin/env bash
# Linux packaging: build the Zig app and engine and produce
#   target/package/harness-<version>-linux-<arch>.tar.gz
# containing harness-nano (the app), harness-engine (the engine the app starts
# and `harness-engine daemon install` runs), the .desktop entry, and the icon,
# plus an install.sh that drops them into ~/.local (XDG) paths. Only Zig
# output ships: no cargo, no Rust binary.
#
# Usage: scripts/package-linux.sh
# Env:   PROFILE=debug for a fast unoptimized package (CI smoke); anything else
#        builds ReleaseSafe (what ships). OPTIMIZE=<Zig mode> overrides.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="${PROFILE:-dist}"
ARCH="$(uname -m)"
VERSION="$(grep -m1 '^version' "$ROOT/Cargo.toml" | sed 's/.*"\(.*\)".*/\1/')"
OUT_DIR="$ROOT/target/package"
STAGE="$OUT_DIR/harness-$VERSION-linux-$ARCH"
TARBALL="$STAGE.tar.gz"

if [[ "$PROFILE" == "debug" ]]; then
  OPTIMIZE="${OPTIMIZE:-Debug}"
else
  OPTIMIZE="${OPTIMIZE:-ReleaseSafe}"
fi

cd "$ROOT"
rm -rf "$STAGE" "$TARBALL"
mkdir -p "$STAGE"
(cd "$ROOT/apps/nano" && "$ROOT/scripts/heavy-build.sh" zig build -Doptimize="$OPTIMIZE")
install -m 755 "$ROOT/apps/nano/zig-out/bin/harness-nano" "$STAGE/harness-nano"
install -m 755 "$ROOT/apps/nano/zig-out/bin/harness-engine" "$STAGE/harness-engine"
ENGINE_VER="$("$STAGE/harness-engine" --version | awk '{print $2}')"
if [[ "$ENGINE_VER" != "$VERSION" ]]; then
  echo "error: harness-engine version ($ENGINE_VER) != Cargo.toml version ($VERSION)" >&2
  exit 1
fi
# The desktop entry opens the Zig app (the template still names the old binary).
sed -e 's/^Exec=harness /Exec=harness-nano /' -e 's/^TryExec=harness$/TryExec=harness-nano/' \
  "$ROOT/dist/harness.desktop" >"$STAGE/harness.desktop"
grep -q '^Exec=harness-nano ' "$STAGE/harness.desktop"
install -m 644 "$ROOT/dist/harness.png" "$STAGE/harness.png"
mkdir -p "$STAGE/licenses/fonts"
cp "$ROOT/apps/nano/assets/fonts/licenses/"* "$STAGE/licenses/fonts/"
cp "$ROOT/LICENSE" "$ROOT/THIRD_PARTY_NOTICES.md" "$STAGE/"
cp "$ROOT/third_party/licenses/Zeron-MIT.txt" "$STAGE/licenses/"
cp "$ROOT/third_party/licenses/CodeGraff-LICENSE.txt" "$STAGE/licenses/"

cat >"$STAGE/install.sh" <<'INSTALL'
#!/usr/bin/env bash
# Install Harness into ~/.local (no root needed).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
install -Dm755 "$HERE/harness-nano" "$HOME/.local/bin/harness-nano"
install -Dm755 "$HERE/harness-engine" "$HOME/.local/bin/harness-engine"
install -Dm644 "$HERE/harness.desktop" "$HOME/.local/share/applications/harness.desktop"
install -Dm644 "$HERE/harness.png" "$HOME/.local/share/icons/hicolor/1024x1024/apps/harness.png"
command -v update-desktop-database >/dev/null 2>&1 \
  && update-desktop-database "$HOME/.local/share/applications" || true
echo "Installed. Make sure ~/.local/bin is on your PATH."
INSTALL
chmod 755 "$STAGE/install.sh"

tar -czf "$TARBALL" -C "$OUT_DIR" "$(basename "$STAGE")"
rm -rf "$STAGE"
echo "packaged: $TARBALL"
tar -tzf "$TARBALL"
