#!/usr/bin/env bash
# macOS packaging: build the Zig app and engine for the host arch and produce
#   target/package/harness-<version>-macos-<arch>.dmg          (user download)
#   target/package/harness-<version>-macos-<arch>-app.tar.gz   (auto-updater)
# containing Harness.app (ad-hoc unless CODESIGN_IDENTITY is set). The app
# and engine are Zig. HARNESS_LORO_PREBUILT optionally ships a separate Rust
# retained-Loro dylib beside them; no Cargo/Rust toolchain is invoked here.
#
# Usage: scripts/package-macos.sh
# Env:   CODESIGN_IDENTITY="Developer ID Application: …" to sign the bundle.
#        GRAFF_BINARY=/absolute/path/to/graff to bundle an exact CLI build.
#        HARNESS_LORO_PREBUILT=/trusted/absolute/libharness_nano_loro.dylib
#        opts into retained Loro; no artifact download or legacy fallback.
#        OPTIMIZE=ReleaseFast|ReleaseSafe|ReleaseSmall for the Zig build
#        (default ReleaseSafe, what ships).
#        NOTARY_KEY_PATH + NOTARY_KEY_ID + NOTARY_ISSUER_ID — App Store Connect
#        API key (.p8) for notarization; all three set → notarize + staple the
#        app and the dmg, which removes the Gatekeeper warning entirely.
#        NOTARYTOOL_PROFILE — alternatively, a keychain profile saved with
#        `xcrun notarytool store-credentials` (local builds).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(sed -n 's/^[[:space:]]*\.version[[:space:]]*=[[:space:]]*"\([0-9][0-9.]*\)",[[:space:]]*$/\1/p' "$ROOT/apps/nano/build.zig.zon" | head -n 1)"
[[ -n "$VERSION" ]] || { echo "error: no .version in apps/nano/build.zig.zon" >&2; exit 1; }
ARCH="$(uname -m)" # arm64 on Apple silicon runners
OUT_DIR="$ROOT/target/package"
APP="$OUT_DIR/Harness.app"
DMG="$OUT_DIR/harness-$VERSION-macos-$ARCH.dmg"
APP_TARBALL="$OUT_DIR/harness-$VERSION-macos-$ARCH-app.tar.gz"
if [[ -n "${GRAFF_BINARY:-}" ]]; then
  [[ -x "$GRAFF_BINARY" ]] || { echo "GRAFF_BINARY is not executable" >&2; exit 1; }
fi

cd "$ROOT"
mkdir -p "$OUT_DIR"
rm -rf "$APP" "$DMG" "$APP_TARBALL"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# One build installs both: harness-nano and harness-engine (apps/nano/build.zig).
LORO_ARGS=()
if [[ -n "${HARNESS_LORO_PREBUILT:-}" ]]; then
  [[ "$HARNESS_LORO_PREBUILT" == /* && -f "$HARNESS_LORO_PREBUILT" ]] || { echo "HARNESS_LORO_PREBUILT must be a trusted absolute dylib file" >&2; exit 1; }
  LORO_ARGS+=("-Dloro-dylib=$HARNESS_LORO_PREBUILT")
fi
(cd "$ROOT/apps/nano" && "$ROOT/scripts/heavy-build.sh" zig build -Doptimize="${OPTIMIZE:-ReleaseSafe}" "${LORO_ARGS[@]}")
install -m 755 "$ROOT/apps/nano/zig-out/bin/harness-nano" "$APP/Contents/MacOS/harness-nano"
install -m 755 "$ROOT/apps/nano/zig-out/bin/harness-engine" "$APP/Contents/MacOS/harness-engine"
if [[ -n "${HARNESS_LORO_PREBUILT:-}" ]]; then
  install -m 755 "$ROOT/apps/nano/zig-out/bin/libharness_nano_loro.dylib" "$APP/Contents/MacOS/libharness_nano_loro.dylib"
fi
sed "s/__VERSION__/$VERSION/" "$ROOT/dist/macos/Info.plist" >"$APP/Contents/Info.plist"
# The app is the Zig binary; the template still names the old executable.
plutil -replace CFBundleExecutable -string harness-nano "$APP/Contents/Info.plist"
[[ "$(plutil -extract CFBundleExecutable raw "$APP/Contents/Info.plist")" == "harness-nano" ]]
# No old Rust engine may ship: the optional Rust library is not an engine.
if [[ -e "$APP/Contents/MacOS/harness" ]]; then
  echo "error: a Rust harness binary is in the bundle" >&2
  exit 1
fi
# ADR 0008: Verify both binaries inside the bundle carry the exact build.zig.zon
# release version so a stale build cache can never trigger an update loop.
ENGINE_VER="$("$APP/Contents/MacOS/harness-engine" --version | awk '{print $2}')"
if [[ "$ENGINE_VER" != "$VERSION" ]]; then
  echo "error: harness-engine version ($ENGINE_VER) != build.zig.zon version ($VERSION)" >&2
  exit 1
fi
# The Zig app embeds build.zig.zon's version as its own string (build_info).
if [[ "$(strings "$APP/Contents/MacOS/harness-nano" | grep -Fxc "$VERSION" || true)" -lt 1 ]]; then
  echo "error: harness-nano binary does not embed version $VERSION (stale .zig-cache)" >&2
  exit 1
fi
# graff ships inside the bundle (Contents/Resources/bin/graff): the app seeds
# ~/.harness/bin/graff from it and links `graff` onto the PATH. GRAFF_BINARY
# overrides; otherwise the latest codegraff release, checked against its
# SHA256SUMS. Release builds are already Developer ID signed and notarized.
GRAFF_ARCH="$ARCH"
[[ "$GRAFF_ARCH" == "arm64" ]] && GRAFF_ARCH=aarch64
mkdir -p "$APP/Contents/Resources/bin"
if [[ -n "${GRAFF_BINARY:-}" ]]; then
  install -m 755 "$GRAFF_BINARY" "$APP/Contents/Resources/bin/graff"
else
  GRAFF_ASSET="graff-$GRAFF_ARCH-macos.tar.gz"
  GRAFF_URL="${GRAFF_RELEASES_URL:-https://github.com/justrach/codegraff/releases/latest/download}"
  GRAFF_TMP="$(mktemp -d)"
  curl -fsSL "$GRAFF_URL/$GRAFF_ASSET" -o "$GRAFF_TMP/$GRAFF_ASSET"
  curl -fsSL "$GRAFF_URL/SHA256SUMS" -o "$GRAFF_TMP/SHA256SUMS"
  (cd "$GRAFF_TMP" && grep " $GRAFF_ASSET\$" SHA256SUMS | shasum -a 256 -c -)
  tar -xzf "$GRAFF_TMP/$GRAFF_ASSET" -C "$GRAFF_TMP"
  GRAFF_SRC="$GRAFF_TMP/graff-$GRAFF_ARCH-macos/graff"
  [[ -f "$GRAFF_SRC" ]] || GRAFF_SRC="$GRAFF_TMP/graff"
  install -m 755 "$GRAFF_SRC" "$APP/Contents/Resources/bin/graff"
  rm -rf "$GRAFF_TMP"
fi
echo "bundled $("$APP/Contents/Resources/bin/graff" --version | head -1)"
# codedb ships beside it (Contents/Resources/bin/codedb): the app seeds
# ~/.harness/tools/bin/codedb from it for the agents, then keeps that copy
# current from codedb's releases. CODEDB_BINARY overrides; otherwise the
# latest codedb release, checked against its checksums.sha256.
if [[ -n "${CODEDB_BINARY:-}" ]]; then
  install -m 755 "$CODEDB_BINARY" "$APP/Contents/Resources/bin/codedb"
else
  CODEDB_ASSET="codedb-darwin-$ARCH"
  CODEDB_URL="${CODEDB_RELEASES_URL:-https://github.com/justrach/codedb/releases/latest/download}"
  CODEDB_TMP="$(mktemp -d)"
  curl -fsSL "$CODEDB_URL/$CODEDB_ASSET" -o "$CODEDB_TMP/$CODEDB_ASSET"
  curl -fsSL "$CODEDB_URL/checksums.sha256" -o "$CODEDB_TMP/checksums.sha256"
  (cd "$CODEDB_TMP" && grep " $CODEDB_ASSET\$" checksums.sha256 | shasum -a 256 -c -)
  install -m 755 "$CODEDB_TMP/$CODEDB_ASSET" "$APP/Contents/Resources/bin/codedb"
  rm -rf "$CODEDB_TMP"
fi
echo "bundled $("$APP/Contents/Resources/bin/codedb" --version | head -1)"
mkdir -p "$APP/Contents/Resources/licenses/fonts"
cp "$ROOT/apps/nano/assets/fonts/licenses/"* "$APP/Contents/Resources/licenses/fonts/"
cp "$ROOT/LICENSE" "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/"
cp "$ROOT/third_party/licenses/Zeron-MIT.txt" "$APP/Contents/Resources/licenses/"
cp "$ROOT/third_party/licenses/CodeGraff-LICENSE.txt" "$APP/Contents/Resources/licenses/"
# Session chimes, by name, for the notification center to play: background
# chimes ride on their banner so Focus applies (apps/nano/src/sound.zig).
for chime in done request attention; do
  cp "$ROOT/apps/nano/assets/sounds/$chime.wav" "$APP/Contents/Resources/harness-$chime.wav"
done

# Icon: iconset from the pre-masked macOS icon (squircle + margins + shadow
# baked into dist/macos/icon-1024.png — sips can't alpha-mask, so the mask is
# applied ahead of time; dist/harness.png stays the full-bleed shared artwork).
ICONSET="$OUT_DIR/harness.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$ROOT/dist/macos/icon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  retina=$((size * 2))
  sips -z "$retina" "$retina" "$ROOT/dist/macos/icon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/harness.icns"
rm -rf "$ICONSET"

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  # Hardened runtime + secure timestamp are both notarization requirements.
  # Sign the optional dylib with the SAME identity before the executables:
  # hardened library validation must not be disabled to load a foreign team.
  if [[ -f "$APP/Contents/MacOS/libharness_nano_loro.dylib" ]]; then
    codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP/Contents/MacOS/libharness_nano_loro.dylib"
  fi
  # graff keeps codegraff's notarized signature unless it isn't Developer ID
  # signed yet (a local GRAFF_BINARY build).
  codesign --verify --strict "$APP/Contents/Resources/bin/graff" 2>/dev/null &&
    codesign -dv "$APP/Contents/Resources/bin/graff" 2>&1 | grep -q "Authority=Developer ID Application" ||
    codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP/Contents/Resources/bin/graff"
  # codedb likewise: keep a Developer ID signature, else sign it ourselves so
  # the bundle notarizes.
  codesign --verify --strict "$APP/Contents/Resources/bin/codedb" 2>/dev/null &&
    codesign -dv "$APP/Contents/Resources/bin/codedb" 2>&1 | grep -q "Authority=Developer ID Application" ||
    codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP/Contents/Resources/bin/codedb"
  # The entitlements let dictation reach the microphone, and dropped or
  # picked files from any folder stay readable, under the hardened runtime
  # (dist/macos/Harness.entitlements).
  codesign --force --options runtime --timestamp \
    --entitlements "$ROOT/dist/macos/Harness.entitlements" --sign "$CODESIGN_IDENTITY" "$APP/Contents/MacOS/harness-nano"
  codesign --force --options runtime --timestamp \
    --entitlements "$ROOT/dist/macos/Harness.entitlements" --sign "$CODESIGN_IDENTITY" "$APP/Contents/MacOS/harness-engine"
  codesign --force --options runtime --timestamp \
    --entitlements "$ROOT/dist/macos/Harness.entitlements" --sign "$CODESIGN_IDENTITY" "$APP"
else
  # Ad-hoc signature so the app launches on Apple silicon (Gatekeeper still
  # requires right-click → Open on first launch without notarization).
  codesign --deep --force --entitlements "$ROOT/dist/macos/Harness.entitlements" --sign - "$APP"
fi

# ADR 0008: Local live-bundle smoke gate before notarization/upload. Launch the
# signed app binary against an isolated temporary HOME and data folder, assert
# that it stays alive (catching both startup crashes and self-update exit
# loops) and that the bundle's Zig engine it starts answers on the port.
if [[ "${CI:-}" != "true" && "${SKIP_SMOKE_LAUNCH:-0}" != "1" ]]; then
  SMOKE_HOME="$(mktemp -d)"
  SMOKE_PORT=49877
  # Discovery must find the bundle's own engine: clear any override inherited
  # from an older launcher's environment.
  unset HARNESS_NANO_ENGINE_BIN HARNESS_NANO_NO_ENGINE_START
  SMOKE_ENV=(HOME="$SMOKE_HOME" HARNESS_DATA_DIR="$SMOKE_HOME/.harness" HARNESS_IPC_PORT="$SMOKE_PORT" HARNESS_AUTH_DISABLED=1)
  smoke_cleanup() {
    kill "$SMOKE_PID" 2>/dev/null || true
    wait "$SMOKE_PID" 2>/dev/null || true
    # The engine outlives the app by design: stop the one the smoke run started.
    local engine_pid
    engine_pid="$(tr -dc 0-9 <"$SMOKE_HOME/.harness/engine.lock" 2>/dev/null || true)"
    [[ -n "$engine_pid" ]] && kill "$engine_pid" 2>/dev/null || true
    rm -rf "$SMOKE_HOME"
  }
  echo "running live smoke check on $APP/Contents/MacOS/harness-nano..."
  env "${SMOKE_ENV[@]}" "$APP/Contents/MacOS/harness-nano" >/dev/null 2>&1 &
  SMOKE_PID=$!
  ENGINE_UP=false
  for _ in $(seq 1 100); do
    if env "${SMOKE_ENV[@]}" "$APP/Contents/MacOS/harness-engine" status 2>/dev/null | grep -q "^IPC:      listening"; then
      ENGINE_UP=true
      break
    fi
    sleep 0.1
  done
  sleep 1
  if ! kill -0 "$SMOKE_PID" 2>/dev/null; then
    smoke_cleanup
    echo "error: $APP/Contents/MacOS/harness-nano exited or crashed on launch" >&2
    exit 1
  fi
  SMOKE_ENGINE_PID="$(tr -dc 0-9 <"$SMOKE_HOME/.harness/engine.lock" 2>/dev/null || true)"
  SMOKE_ENGINE_CMD="$( [[ -n "$SMOKE_ENGINE_PID" ]] && ps -o command= -p "$SMOKE_ENGINE_PID" || true)"
  SMOKE_ENGINE_WANT="$(cd "$APP/Contents/MacOS" && pwd -P)/harness-engine headless"
  if ! $ENGINE_UP || [[ "$SMOKE_ENGINE_CMD" != "$SMOKE_ENGINE_WANT" ]]; then
    smoke_cleanup
    echo "error: harness-nano did not start the bundled harness-engine (running: ${SMOKE_ENGINE_CMD:-nothing})" >&2
    exit 1
  fi
  smoke_cleanup
  echo "live smoke check passed: harness-nano stayed up and started harness-engine."
fi

# notarize <path>: submit to Apple and wait for the verdict. A rejection may
# still exit 0 depending on the notarytool version — the `stapler staple` that
# follows each call has no ticket to attach then, and fails the build for us.
NOTARY_AUTH=()
if [[ -n "${NOTARY_KEY_PATH:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER_ID:-}" ]]; then
  NOTARY_AUTH=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
elif [[ -n "${NOTARYTOOL_PROFILE:-}" ]]; then
  NOTARY_AUTH=(--keychain-profile "$NOTARYTOOL_PROFILE")
fi
notarize() {
  xcrun notarytool submit "$1" "${NOTARY_AUTH[@]}" --wait
}
NOTARIZE=false
[[ ${#NOTARY_AUTH[@]} -gt 0 ]] && NOTARIZE=true
if $NOTARIZE && [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
  echo "notarization requires CODESIGN_IDENTITY (Developer ID Application)" >&2
  exit 1
fi

if $NOTARIZE; then
  # Staple the bundle BEFORE tarring it: the auto-updater swaps the .app with
  # no dmg involved, so the tarball copy must carry its own ticket to pass
  # Gatekeeper offline.
  ZIP="$OUT_DIR/harness-notarize.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  notarize "$ZIP"
  rm -f "$ZIP"
  xcrun stapler staple "$APP"
fi

# The auto-updater artifact. COPYFILE_DISABLE keeps macOS tar from adding
# AppleDouble `._Harness.app` entries (extended attributes) beside the bundle.
COPYFILE_DISABLE=1 tar -czf "$APP_TARBALL" -C "$OUT_DIR" Harness.app
echo "packaged: $APP_TARBALL"

# The dmg presents the classic drag-into-Applications layout over the
# Codegraff workshop artwork (committed renders from scripts/dmg-background.swift).
# dmgbuild writes the .DS_Store (background, icon view, icon positions)
# directly — no Finder scripting, so it also works on headless CI runners.
PY_BIN=python3
if ! python3 -c 'import dmgbuild' 2>/dev/null &&
  ! python3 -m pip install --quiet --user dmgbuild 2>/dev/null &&
  ! python3 -m pip install --quiet --user --break-system-packages dmgbuild 2>/dev/null; then
  # An active virtualenv refuses --user installs; use a throwaway venv.
  python3 -m venv "$OUT_DIR/dmgbuild-venv"
  "$OUT_DIR/dmgbuild-venv/bin/pip" install --quiet dmgbuild
  PY_BIN="$OUT_DIR/dmgbuild-venv/bin/python"
fi

# Pair the 1x/2x background renders into a hidpi tiff so the artwork stays
# crisp on retina displays.
BG_TIFF="$OUT_DIR/dmg-background.tiff"
tiffutil -cathidpicheck "$ROOT/dist/macos/dmg-background.png" \
  "$ROOT/dist/macos/dmg-background@2x.png" -out "$BG_TIFF" >/dev/null 2>&1

APP="$APP" DMG="$DMG" BG_TIFF="$BG_TIFF" "$PY_BIN" - <<'PY'
import os
import dmgbuild

app = os.environ["APP"]
dmgbuild.build_dmg(
    filename=os.environ["DMG"],
    volume_name="Harness",
    settings={
        "format": "UDZO",
        "files": [app],
        "symlinks": {"Applications": "/Applications"},
        "icon": os.path.join(app, "Contents/Resources/harness.icns"),
        "background": os.environ["BG_TIFF"],
        "show_status_bar": False,
        "show_tab_view": False,
        "show_toolbar": False,
        "show_pathbar": False,
        "show_sidebar": False,
        "default_view": "icon-view",
        # Window and icon geometry must match scripts/dmg-background.swift.
        "window_rect": ((200, 120), (660, 400)),
        "icon_size": 104,
        "text_size": 12,
        "icon_locations": {"Harness.app": (165, 195), "Applications": (495, 195)},
    },
)
PY
rm -f "$BG_TIFF"
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  # Gatekeeper assesses the dmg's own signature too, not just the app inside.
  codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$DMG"
fi
if $NOTARIZE; then
  notarize "$DMG"
  xcrun stapler staple "$DMG"
fi
echo "packaged: $DMG"
