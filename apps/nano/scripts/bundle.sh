#!/bin/sh
# Builds harness-nano for release and wraps it as zig-out/Harness Nano.app.
set -eu
cd "$(dirname "$0")/.."
# ReleaseSafe: a bug panics with a stack trace in the crash log instead of
# corrupting memory, for 0.1 MB and no measurable CPU in the resource replay
# (8.9% streaming against ReleaseFast's 9.7%, the same within noise).
zig build --release=safe -j1 "$@"
dynamic_loro=false
for arg in "$@"; do
    case "$arg" in -Dloro-dylib=*) dynamic_loro=true ;; esac
done
# Use the version embedded in the executable: build.zig.zon's `.version`
# (build.zig). Refuse a placeholder bundle when it is missing or malformed.
version=$(sed -n 's/^[[:space:]]*\.version[[:space:]]*=[[:space:]]*"\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)",[[:space:]]*$/\1/p' build.zig.zon | head -n 1)
if [ -z "$version" ]; then
    echo "Cannot package Harness Nano: missing .version in build.zig.zon" >&2
    exit 1
fi
# The app icon: the repository's macOS icon (squircle and margins baked in).
icon_png=../../dist/macos/icon-1024.png
if [ ! -f "$icon_png" ]; then
    echo "Cannot package Harness Nano: missing app icon $icon_png" >&2
    exit 1
fi
app="zig-out/Harness Nano.app/Contents"
# Rebuild only this generated bundle's contents: old local bundles may still
# contain a retired engine or nested signatures from a different build mode.
rm -rf "$app"
mkdir -p "$app/MacOS" "$app/Resources"
cp zig-out/bin/harness-nano "$app/MacOS/"
# The engine the app starts: the one beside its own executable, so the two
# versions always match (src/engine_start.zig).
if [ ! -x zig-out/bin/harness-engine ]; then
    echo "Cannot package Harness Nano: the build did not produce harness-engine" >&2
    exit 1
fi
cp zig-out/bin/harness-engine "$app/MacOS/"
# Only an explicitly selected dynamic build ships a library; never infer mode
# from an old zig-out file left behind by a previous installation.
rm -f "$app/MacOS/libharness_nano_loro.dylib"
if "$dynamic_loro"; then
    cp zig-out/bin/libharness_nano_loro.dylib "$app/MacOS/"
    codesign --force --sign - "$app/MacOS/libharness_nano_loro.dylib"
fi
iconset_dir=$(mktemp -d)
trap 'rm -rf "$iconset_dir"' EXIT
iconset="$iconset_dir/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$icon_png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    sips -z "$retina" "$retina" "$icon_png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Resources/AppIcon.icns"
cat > "$app/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Harness Nano</string>
<key>CFBundleIdentifier</key><string>com.justrach.harness-nano</string>
<key>CFBundleExecutable</key><string>harness-nano</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$version</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
# Copying over a linker-signed executable can invalidate its mapped pages.
# Re-seal the complete bundle after the executable, icon and plist are final.
codesign --force --sign - "$app/MacOS/harness-engine"
codesign --force --sign - "$app/MacOS/harness-nano"
codesign --force --sign - "zig-out/Harness Nano.app"
echo "zig-out/Harness Nano.app"
