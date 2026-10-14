"""Verify pinned data and package offline resources plus MPL-covered source."""
from pathlib import Path
import hashlib
import json
import shutil
import sys
import zipfile

root = Path(__file__).resolve().parent.parent
data = root / "Sources/SwitcherCore/Resources/Dictionaries"
for name, info in json.loads((data / "provenance.json").read_text())["files"].items():
    content = (data / name).read_bytes()
    if len(content) != info["bytes"] or hashlib.sha256(content).hexdigest() != info["sha256"]:
        raise SystemExit("Pinned dictionary verification failed: " + name)

app = Path(sys.argv[1]) if len(sys.argv) == 2 else root / "Build/Trump Switcher.app"
if app.suffix != ".app":
    raise SystemExit("Expected an application bundle destination")
dest = app / "Contents/Resources/Dictionaries"
if dest.exists():
    shutil.rmtree(dest)
shutil.copytree(data, dest)
shutil.copy2(root / "THIRD_PARTY.md", dest / "THIRD_PARTY.md")
shutil.copy2(root / "Assets/TrumpAppIcon.icns", dest.parent / "TrumpAppIcon.icns")
(dest.parent / "ChromeInputCheck.html").unlink(missing_ok=True)
(dest.parent / "TrumpProfile.png").unlink(missing_ok=True)
for suffix in ["", "@2x", "@3x"]:
    name = f"TrumpMenuBar{suffix}.png"
    shutil.copy2(root / "Assets" / name, dest.parent / name)
with zipfile.ZipFile(dest / "Licenses/Hunspell/Source.zip", "w", zipfile.ZIP_DEFLATED) as archive:
    for directory in [root / "Sources/Hunspell", data / "Licenses/Hunspell"]:
        for file in sorted(directory.rglob("*")):
            if file.is_file():
                archive.write(file, file.relative_to(root))
    for file in [root / "Package.swift", root / "THIRD_PARTY.md"]:
        archive.write(file, file.relative_to(root))
print("Verified and packaged offline dictionaries, licenses and Hunspell source")
