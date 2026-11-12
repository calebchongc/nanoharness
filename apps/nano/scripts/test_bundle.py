"""The release bundler must build the same dependency that was tested."""
import os
import plistlib
from pathlib import Path
import subprocess
import tempfile
import unittest


class BundleArgumentsTests(unittest.TestCase):
    def test_dependency_override_and_build_options_reach_zig(self):
        source = Path(__file__).with_name("bundle.sh")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "scripts").mkdir()
            (root / "bin").mkdir()
            script = root / "scripts/bundle.sh"
            script.write_bytes(source.read_bytes())
            zig = root / "bin/zig"
            # Stop before packaging: no compiler, installed app, or real data.
            zig.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\nexit 73\n')
            zig.chmod(0o755)
            result = subprocess.run(
                ["sh", str(script), "--fork=/synthetic/nanoui", "-j1"],
                env={**os.environ, "PATH": str(root / "bin") + os.pathsep + os.environ["PATH"]},
                capture_output=True,
                text=True,
                timeout=60,
            )
            self.assertEqual(result.returncode, 73, result.stderr)
            self.assertEqual(result.stdout.splitlines(), [
                "build", "--release=safe", "-j1", "--fork=/synthetic/nanoui", "-j1",
            ])


SIPS = """#!/bin/sh
# Records each resize and writes its output, as sips would.
out=""
while [ $# -gt 0 ]; do
    case "$1" in --out) out="$2"; shift ;; esac
    shift
done
printf png > "$out"
"""
ICONUTIL = """#!/bin/sh
# iconutil -c icns <iconset> -o <file>
set -eu
test "$(ls "$3" | wc -l | tr -d ' ')" = 10
printf icns > "$5"
"""

MANIFEST = """.{
    .name = .harness_nano,
    .version = "%s",
    .fingerprint = 0x1,
    .minimum_zig_version = "0.17.0",
    .dependencies = .{
        .nanoui = .{
            .url = "git+https://example.invalid/nanoui#0",
            .hash = "nanoui-4.5.6-synthetic",
        },
    },
}
"""


class BundleVersionTests(unittest.TestCase):
    def bundle(self, manifest, icon=True):
        source = Path(__file__).with_name("bundle.sh")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            nano = root / "apps/nano"
            (nano / "scripts").mkdir(parents=True)
            (root / "bin").mkdir()
            if manifest is not None:
                (nano / "build.zig.zon").write_text(manifest)
            if icon:
                (root / "dist/macos").mkdir(parents=True)
                (root / "dist/macos/icon-1024.png").write_bytes(b"synthetic png")
            script = nano / "scripts/bundle.sh"
            script.write_bytes(source.read_bytes())
            tools = {
                "zig": '#!/bin/sh\nmkdir -p zig-out/bin\nprintf synthetic > zig-out/bin/harness-nano\n',
                "codesign": '#!/bin/sh\ntest -f "zig-out/Harness Nano.app/Contents/Info.plist"\n',
                "sips": SIPS,
                "iconutil": ICONUTIL,
            }
            for name, body in tools.items():
                tool = root / "bin" / name
                tool.write_text(body)
                tool.chmod(0o755)
            result = subprocess.run(
                ["sh", str(script)],
                env={**os.environ, "PATH": str(root / "bin") + os.pathsep + os.environ["PATH"]},
                capture_output=True,
                text=True,
                timeout=60,
            )
            contents = nano / "zig-out/Harness Nano.app/Contents"
            info = contents / "Info.plist"
            icns = contents / "Resources/AppIcon.icns"
            return (
                result,
                plistlib.loads(info.read_bytes()) if info.exists() else None,
                icns.read_bytes() if icns.exists() else None,
            )

    def test_bundle_versions_match_the_manifest_not_another_field(self):
        result, info, _ = self.bundle(MANIFEST % "9.8.7")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(info["CFBundleShortVersionString"], "9.8.7")
        self.assertEqual(info["CFBundleVersion"], "9.8.7")

    def test_missing_version_does_not_ship_a_placeholder(self):
        for manifest in (None, MANIFEST.replace('    .version = "%s",\n', ""), MANIFEST % "next"):
            result, info, _ = self.bundle(manifest)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(".version in build.zig.zon", result.stderr)
            self.assertIsNone(info)

    def test_icon_comes_from_the_repository_not_an_installed_app(self):
        result, info, icns = self.bundle(MANIFEST % "1.2.3")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(icns, b"icns")
        self.assertEqual(info["CFBundleIconFile"], "AppIcon")
        self.assertNotIn("/Applications", Path(__file__).with_name("bundle.sh").read_text())

    def test_missing_icon_fails_instead_of_shipping_without_one(self):
        result, info, _ = self.bundle(MANIFEST % "1.2.3", icon=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("app icon", result.stderr)
        self.assertIsNone(info)


if __name__ == "__main__":
    unittest.main()
