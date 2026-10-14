#!/usr/bin/env python3
"""Check only the owned release bundle; no UI, event taps or other apps."""
import hashlib
import json
from pathlib import Path
import plistlib
import struct
import subprocess
import sys
import zipfile

if not __debug__:
    raise SystemExit("Release verification must run without Python optimization")

app = Path(sys.argv[1]).resolve()
info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
assert info["CFBundleIdentifier"] == "local.trumpswitcher.mac"
assert info["CFBundleExecutable"] == "TrumpSwitcher"
assert info["LSMinimumSystemVersion"] == "13.0"
assert info["CFBundleShortVersionString"] == "0.6.32" and info["CFBundleVersion"] == "71"
binary = app / "Contents/MacOS/TrumpSwitcher"
assert sorted(p.name for p in binary.parent.iterdir()) == ["TrumpSwitcher"]
subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(app)], check=True)
assert subprocess.check_output(["/usr/bin/lipo", "-archs", str(binary)], text=True).strip() == "arm64"
dependencies = subprocess.check_output(["/usr/bin/otool", "-L", str(binary)], text=True)
for line in dependencies.splitlines()[1:]:
    dependency = line.strip().split(" (", 1)[0]
    assert dependency.startswith(("/System/Library/", "/usr/lib/")), dependency
load_commands = subprocess.check_output(["/usr/bin/otool", "-l", str(binary)], text=True)
assert "minos 13.0" in load_commands and "sdk 26.5" in load_commands
data = binary.read_bytes()
for name in [b"--check-chrome-input", b"--check-input-pipeline", b"ChromeInputChecks", b"InputPipelineChecks"]:
    assert name not in data, "Interactive diagnostic shipped: " + name.decode()
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
assert (resources / "TrumpAppIcon.icns").read_bytes()[:4] == b"icns"
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
                  "architecture": "arm64", "minimumMacOS": info["LSMinimumSystemVersion"],
                  "binarySHA256": hashlib.sha256(data).hexdigest(), "pinnedFiles": len(provenance["files"]),
                  "signature": "verified", "interactiveDiagnostics": "excluded", "uiOrExternalAppAccess": False}, indent=2))
