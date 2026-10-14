#!/usr/bin/env python3
"""Check the image itself, without opening Finder or launching its application."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

from ds_store import DSStore
from mac_alias import Alias

image = Path(sys.argv[1]).resolve()
source = Path(sys.argv[2]).resolve()
expected_positions = {"Trump Switcher.app": (185, 272), "Программы": (575, 272)}

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
        visible = sorted(p.name for p in mount.iterdir() if not p.name.startswith("."))
        assert visible == sorted(expected_positions), visible
        with DSStore.open(str(mount / ".DS_Store"), "r") as store:
            window = store["."]["bwsp"]
            icons = store["."]["icvp"]
            positions = {name: store[name]["Iloc"] for name in expected_positions}
            assert positions == expected_positions, positions
            assert window["WindowBounds"].endswith("{760, 480}}"), window
            assert not any(window[key] for key in ["ShowToolbar", "ShowSidebar",
                                                  "ShowStatusBar", "ShowPathbar", "ShowTabView"])
            assert icons["backgroundType"] == 2
            assert icons["iconSize"] == 128 and icons["textSize"] == 14
            assert icons["arrangeBy"] == "none"
            alias = Alias.from_bytes(icons["backgroundImageAlias"])
            assert alias.target.filename == ".background.tiff", alias.target.filename
        root = Path(__file__).resolve().parent.parent
        assert digest(mount / ".background.tiff") == digest(root / "Assets/Installer/background.tiff")
        assert (mount / ".Установка.txt").is_file()
        report = {"application_files_identical": len(source_files),
                  "application_signature_valid": True, "applications_link_valid": True,
                  "visible_items": visible, "icon_positions": positions,
                  "window_bounds": window["WindowBounds"],
                  "background_embedded": True,
                  "image_sha256": digest(image), "scope": "Read-only image inspection; no application launch or Finder UI automation"}
        print(json.dumps(report, ensure_ascii=False, indent=2))
    finally:
        subprocess.run(["hdiutil", "detach", "-quiet", str(mount)], check=True)
