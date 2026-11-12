#!/usr/bin/env python3
"""Bounded synthetic engine startup regressions for the macOS Loro loader."""
import os
from pathlib import Path
import socket
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
ENGINE = Path(os.environ.get("LORO_TEST_ENGINE", ROOT / "apps/nano/zig-out/bin/harness-engine")).resolve()


def rejected(library, expected, extra_env=None, executable=None):
    with tempfile.TemporaryDirectory(prefix="nano-dylib-reject-") as tmp:
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            port = s.getsockname()[1]
        env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": tmp,
               "TMPDIR": tmp, "HARNESS_DATA_DIR": tmp + "/data",
               "HARNESS_IPC_PORT": str(port), "HARNESS_NANO_NO_RELEASE_CHECK": "1"}
        if library is not None:
            env["HARNESS_NANO_LORO_LIBRARY"] = str(library)
        env.update(extra_env or {})
        p = subprocess.Popen([str(executable or ENGINE), "headless"], env=env,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        try:
            output = p.communicate(timeout=5)[0].decode(errors="replace")
        except subprocess.TimeoutExpired:
            p.terminate()
            p.communicate(timeout=5)
            raise AssertionError("requested invalid library was ignored: engine remained running")
        assert p.returncode != 0, "invalid library was accepted"
        assert expected in output, (expected, output)
        assert not Path(tmp, "data").exists(), "loader failure touched the profile"
        print("PASS", expected)


if __name__ == "__main__":
    rejected("/nonexistent/synthetic/libharness_nano_loro.dylib", "LoroLibraryMissing")
    rejected("libharness_nano_loro.dylib", "LoroLibraryPathNotAbsolute")
    rejected("", "LoroLibraryPathNotAbsolute")
    rejected("/nonexistent/synthetic/libharness_nano_loro.dylib", "LoroAmbientLoaderOverride",
             {"DYLD_LIBRARY_PATH": str(ENGINE.parent)})
    with tempfile.TemporaryDirectory(prefix="nano-dylib-fixtures-") as tmp:
        fixture = ROOT / "scripts/fixtures/loro-loader.c"
        for name, flags, error in [
            ("wrong-abi", ["-DABI=2"], "LoroAbiMismatch"),
            ("missing-capabilities", ["-DCAPS=1"], "LoroCapabilitiesMissing"),
            ("missing-symbol", ["-DOMIT_CALL=1"], "LoroSymbolMissing"),
            ("wrong-architecture", ["-target", "x86_64-apple-macos13"], "LoroArchitectureMismatch"),
        ]:
            if name == "wrong-architecture" and os.uname().machine != "arm64":
                flags = ["-target", "arm64-apple-macos13"]
            out = Path(tmp, name + ".dylib")
            subprocess.run(["/usr/bin/xcrun", "clang", "-dynamiclib", str(fixture),
                            "-o", str(out)] + flags, check=True, timeout=30,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            rejected(out, error)
        invalid = Path(tmp, "invalid.dylib")
        invalid.write_bytes(b"not a dynamic library\n")
        rejected(invalid, "LoroInvalidLibrary")
    print("PASS rejected invalid libraries before opening synthetic profiles; no fallback")
    if len(sys.argv) > 1:
        bundle = Path(sys.argv[1]).resolve()
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(bundle)], check=True)
        with tempfile.TemporaryDirectory(prefix="nano-relocated-") as tmp:
            moved = Path(tmp, "renamed folder", "Relocated Nano.app")
            shutil.copytree(bundle, moved)
            bin_dir = moved / "Contents/MacOS"
            lib = bin_dir / "libharness_nano_loro.dylib"
            identity = subprocess.check_output(["/usr/bin/otool", "-D", str(lib)], text=True).splitlines()[1:]
            assert identity == ["@rpath/libharness_nano_loro.dylib"], identity
            linked = subprocess.check_output(["/usr/bin/otool", "-L", str(lib)], text=True).splitlines()[2:]
            assert all(line.strip().startswith(("/usr/lib/", "/System/Library/")) for line in linked), linked
            for artifact in [lib, bin_dir / "harness-engine", bin_dir / "harness-nano"]:
                contents = artifact.read_bytes()
                assert str(ROOT).encode() not in contents, "developer checkout path embedded in distributable"
                assert str(Path.home()).encode() not in contents, "developer home path embedded in distributable"
            for binary in ["harness-engine", "harness-nano"]:
                symbols = subprocess.check_output(["/usr/bin/nm", "-u", str(bin_dir / binary)], text=True)
                assert "_harness_loro_" not in symbols, "Rust functions must resolve at runtime"
            hidden = lib.with_suffix(".held")
            lib.rename(hidden)
            try:
                # Both entry points fail before opening windows/profiles. The
                # executable's requested default may not search cwd or the
                # original build tree when the bundled artifact is absent.
                for binary in ["harness-engine", "harness-nano"]:
                    rejected(None, "LoroLibraryMissing", executable=bin_dir / binary)
            finally:
                hidden.rename(lib)
            rejected("/nonexistent/synthetic/explicit.dylib", "LoroLibraryMissing",
                     executable=bin_dir / "harness-engine")
            subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(moved)], check=True)
        print("PASS relocated bundle signatures, runtime-only symbols, safe install ID/system dependencies, missing-artifact failure")
