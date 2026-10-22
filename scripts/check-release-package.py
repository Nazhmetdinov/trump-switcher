#!/usr/bin/env python3
"""Check only the owned release bundle; no UI, event taps or other apps."""
import hashlib
import json
import platform
from pathlib import Path
import plistlib
import struct
import subprocess
import sys
import zipfile

if not __debug__:
    raise SystemExit("Release verification must run without Python optimization")

app = Path(sys.argv[1]).resolve()
expected_arch = sys.argv[2] if len(sys.argv) > 2 else "arm64"
assert expected_arch in {"arm64", "x86_64"}, expected_arch
info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
assert info["CFBundleIdentifier"] == "local.trumpswitcher.mac"
assert info["CFBundleExecutable"] == "TrumpSwitcher"
assert info["LSMinimumSystemVersion"] == "13.0"
assert info["LSUIElement"] is True, "The app must run from the menu bar without a Dock icon"
assert info["CFBundleShortVersionString"] == "0.6.45" and info["CFBundleVersion"] == "84"
binary = app / "Contents/MacOS/TrumpSwitcher"
assert sorted(p.name for p in binary.parent.iterdir()) == ["TrumpSwitcher"]
subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(app)], check=True)
assert subprocess.check_output(["/usr/bin/lipo", "-archs", str(binary)], text=True).strip() == expected_arch
dependencies = subprocess.check_output(["/usr/bin/otool", "-L", str(binary)], text=True)
for line in dependencies.splitlines()[1:]:
    dependency = line.strip().split(" (", 1)[0]
    assert dependency.startswith(("/System/Library/", "/usr/lib/")), dependency
load_commands = subprocess.check_output(["/usr/bin/otool", "-l", str(binary)], text=True)
assert "minos 13.0" in load_commands and "sdk 26.5" in load_commands
data = binary.read_bytes()
for name in [b"--check-chrome-input", b"--check-input-pipeline", b"ChromeInputChecks", b"InputPipelineChecks"]:
    assert name not in data, "Interactive diagnostic shipped: " + name.decode()
if platform.machine() == expected_arch:
    for flag in ["--check-chrome-input", "--check-input-pipeline"]:
        result = subprocess.run([str(binary), flag], capture_output=True, text=True, timeout=10)
        assert result.returncode == 2 and "Unsupported command" in result.stderr, flag
resources = app / "Contents/Resources"
assert sorted(p.name for p in resources.iterdir()) == [
    "Dictionaries", "TrumpAppIcon.icns", "TrumpMenuBar.png", "TrumpMenuBar@2x.png", "TrumpMenuBar@3x.png"]
for scale, suffix in [(1, ""), (2, "@2x"), (3, "@3x")]:
    png = (resources / ("TrumpMenuBar" + suffix + ".png")).read_bytes()
    assert png[:8] == b"\x89PNG\r\n\x1a\n"
    assert struct.unpack(">II", png[16:24]) == (22 * scale, 22 * scale)
    assert png[25] == 6, "Menu icon must be RGBA"
icon = (resources / "TrumpAppIcon.icns").read_bytes()
assert icon[:4] == b"icns" and struct.unpack_from(">I", icon, 4)[0] == len(icon)
icon_entries = {}
offset = 8
while offset < len(icon):
    tag = icon[offset:offset + 4]
    size = struct.unpack_from(">I", icon, offset + 4)[0]
    assert size >= 8 and offset + size <= len(icon) and tag not in icon_entries
    icon_entries[tag] = icon[offset + 8:offset + size]
    offset += size
assert offset == len(icon)
assert b"icp4" not in icon_entries and b"icp5" not in icon_entries and b"icp6" not in icon_entries
assert icon_entries[b"ic04"].startswith(b"ARGB") and icon_entries[b"ic05"].startswith(b"ARGB"), \
    "16/32-pixel ICNS entries must use native ARGB, not PNG"
assert all(icon_entries[tag].startswith(b"\x89PNG\r\n\x1a\n") for tag in
           (b"ic07", b"ic08", b"ic09", b"ic10", b"ic11", b"ic12", b"ic13", b"ic14"))
dictionaries = resources / "Dictionaries"
provenance = json.loads((dictionaries / "provenance.json").read_text())
for name, pinned in provenance["files"].items():
    content = (dictionaries / name).read_bytes()
    assert len(content) == pinned["bytes"] and hashlib.sha256(content).hexdigest() == pinned["sha256"], name
assert (dictionaries / "THIRD_PARTY.md").is_file()
with zipfile.ZipFile(dictionaries / "Licenses/Hunspell/Source.zip") as source:
    assert source.testzip() is None
    assert "Sources/Hunspell/COPYING.MPL" in source.namelist() or any(name.endswith("/COPYING.MPL") for name in source.namelist())
print(json.dumps({"version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
                  "architecture": expected_arch, "minimumMacOS": info["LSMinimumSystemVersion"],
                  "binarySHA256": hashlib.sha256(data).hexdigest(), "pinnedFiles": len(provenance["files"]),
                  "signature": "verified", "interactiveDiagnostics": "excluded",
                  "runtimeChecks": "passed" if platform.machine() == expected_arch else "requires target hardware",
                  "uiOrExternalAppAccess": False}, indent=2))
