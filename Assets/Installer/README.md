# Trump Switcher installer artwork

The Finder content area is 760 × 480 points. The native application and
Applications-link icons are 128 points, centered at (185, 272) and (575, 272).
Only the typography, arrow, privacy footer, and background are raster artwork.
`preview.png` is a composited layout preview, not a Finder screenshot.

`background.tiff` includes 760 × 480 and 1520 × 960 representations, both at
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
inventory and code signature, the two visible items, Applications symlink,
background, icon locations, and window settings before publishing the image.

Build-tool documentation: [dmgbuild](https://dmgbuild.readthedocs.io/en/latest/settings.html),
[ds_store](https://github.com/dmgbuild/ds_store),
[mac_alias](https://github.com/dmgbuild/mac_alias).
These tools are not bundled with or used by Trump Switcher at runtime.
