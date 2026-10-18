#!/usr/bin/env python3
"""Check the image itself, without opening Finder or launching its application."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unicodedata

from ds_store import DSStore
from mac_alias import Alias

image = Path(sys.argv[1]).resolve()
source = Path(sys.argv[2]).resolve()
artwork = Path(sys.argv[3]).resolve() if len(sys.argv) > 3 else Path(__file__).resolve().parent.parent / "Assets/Installer"
architecture = subprocess.check_output(["lipo", "-archs", str(source / "Contents/MacOS/TrumpSwitcher")], text=True).strip()
version = plistlib.loads((source / "Contents/Info.plist").read_bytes())["CFBundleShortVersionString"]
expected_volume = ("Trump Switcher Intel" if architecture == "x86_64" else "Trump Switcher") + " " + version
shortcut_name = "Настройки безопасности.url"
expected_positions = {"Trump Switcher.app": (185, 205), "Программы": (575, 205),
                      shortcut_name: (600, 408)}

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

with tempfile.TemporaryDirectory(prefix="trumpswitcher-image-check-") as temporary:
    mount = Path(temporary) / "image"
    mount.mkdir()
    subprocess.run(["hdiutil", "attach", "-quiet", "-readonly", "-nobrowse", "-noautoopen",
                    "-mountpoint", str(mount), str(image)], check=True)
    try:
        app = mount / "Trump Switcher.app"
        subprocess.run(["codesign", "--verify", "--strict", str(app)], check=True)
        source_files = {str(p.relative_to(source)): digest(p)
                        for p in source.rglob("*") if p.is_file()}
        image_files = {str(p.relative_to(app)): digest(p)
                       for p in app.rglob("*") if p.is_file()}
        assert source_files == image_files, "Image application differs from release"
        assert (mount / "Программы").is_symlink()
        assert os.readlink(mount / "Программы") == "/Applications"
        # HFS+ decomposes characters such as Russian й in on-disk names.
        visible = sorted(unicodedata.normalize("NFC", p.name)
                         for p in mount.iterdir() if not p.name.startswith("."))
        assert visible == sorted(expected_positions), visible
        with DSStore.open(str(mount / ".DS_Store"), "r") as store:
            window = store["."]["bwsp"]
            icons = store["."]["icvp"]
            positions = {name: store[unicodedata.normalize("NFD", name)]["Iloc"]
                         for name in expected_positions}
            assert positions == expected_positions, positions
            assert window["WindowBounds"].endswith("{760, 632}}"), window
            assert not any(window[key] for key in ["ShowToolbar", "ShowSidebar",
                                                  "ShowStatusBar", "ShowPathbar", "ShowTabView"])
            assert icons["backgroundType"] == 2
            assert icons["iconSize"] == 128 and icons["textSize"] == 14
            assert icons["arrangeBy"] == "none"
            alias = Alias.from_bytes(icons["backgroundImageAlias"])
            assert alias.target.filename == ".background.tiff", alias.target.filename
            assert alias.volume.name == expected_volume, alias.volume.name
            assert alias.volume.posix_path == "/Volumes/" + expected_volume, alias.volume.posix_path
            bookmark = store["."]["pBBk"].tocs[0][1]
            assert bookmark[0x2010] == expected_volume, bookmark.get(0x2010)
            assert bookmark[0x2002] == "/Volumes/" + expected_volume, (
                "Background bookmark refers to a differently mounted volume; eject other installers before packaging",
                bookmark.get(0x2002))
        assert digest(mount / ".background.tiff") == digest(artwork / "background.tiff")
        assert (mount / ".Установка.txt").is_file()
        shortcut = mount / shortcut_name
        assert shortcut.read_text() == (
            "[InternetShortcut]\n"
            "URL=x-apple.systempreferences:com.apple.preference.security?General\n")
        assert not (shortcut.stat().st_mode & 0o111), "Shortcut must not be executable"
        subprocess.run(["xattr", "-p", "com.apple.ResourceFork", str(shortcut)],
                       check=True, stdout=subprocess.DEVNULL)
        report = {"application_files_identical": len(source_files),
                  "application_signature_valid": True, "applications_link_valid": True,
                  "visible_items": visible, "icon_positions": positions,
                  "window_bounds": window["WindowBounds"],
                  "background_embedded": True,
                  "security_shortcut_valid": True,
                  "image_sha256": digest(image), "scope": "Read-only image inspection; no application launch or Finder UI automation"}
        print(json.dumps(report, ensure_ascii=False, indent=2))
    finally:
        subprocess.run(["hdiutil", "detach", "-quiet", str(mount)], check=True)
