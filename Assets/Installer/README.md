# Trump Switcher installer artwork

The Finder content area is 760 × 600 points. The native application and
Applications-link icons are 128 points, centered at (185, 205) and (575, 205).
The security-settings URL shortcut is centered at (600, 420). Its native Settings
icon is applied only to the staged data file, preserving the signed app bundle.
Only the typography, arrow, privacy footer, and background are raster artwork.
`preview.png` is a composited layout preview, not a Finder screenshot.

`background.tiff` includes 760 × 600 and 1520 × 1200 representations, both at
the same logical size. Finder loads this embedded file through the volume's
own background alias; no path on the build computer is required at install time.

Regenerate artwork on macOS:

```sh
swift scripts/prepare-installer-art.swift "$PWD"
```

Build the disk image with the packaging Python containing the pinned build-only
dependencies in `scripts/installer-requirements.txt`:

```sh
DMGBUILD_PYTHON=/path/to/packaging/python scripts/package-release.sh '/path/to/Trump Switcher.app'
```

Set `TRUMP_DMG_ONLY=1` to retain the ZIP archive when re-styling an existing
release. The package script checks the embedded application's complete file
inventory and code signature, the three visible items, Applications symlink,
the exact settings URL, background, icon locations, and window settings.
The `-setup3` DMG name distinguishes the revised installer from the original
published artifact without changing the application or its signature.

The data-only `.url` opens Privacy & Security on a user double-click, including
before the app has permission to launch. It cannot open automatically on mount
or approve Gatekeeper, and never removes quarantine or changes security settings.
Users must first attempt to launch the copied app for its Open Anyway entry to
appear. The shortcut pattern is also used by [Fuji](https://github.com/Lazza/Fuji/blob/master/packaging/Full%20Disk%20Access%20Settings.url).

Build-tool documentation: [dmgbuild](https://dmgbuild.readthedocs.io/en/latest/settings.html),
[ds_store](https://github.com/dmgbuild/ds_store),
[mac_alias](https://github.com/dmgbuild/mac_alias).
These tools are not bundled with or used by Trump Switcher at runtime.

The 760 × 632 Finder window includes a 32-point title bar. The 600-point
artwork leaves a bottom margin and all content fits without scrolling. Native
file labels sit on light plates for contrast. The art renderer rejects text
that falls outside the canvas.
