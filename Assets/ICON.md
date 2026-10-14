# Trump Switcher artwork

The app icon is a new illustration generated independently for this project.
`TrumpAppIcon-original-generated.png` is the local source. The deterministic
AppKit script `scripts/prepare-app-icon.swift` crops and masks it to a clean
rounded tile at the ten standard sizes. `scripts/pack-app-icon.py` packs those
PNG representations into `TrumpAppIcon.icns`.

The menu-bar icon is a pair of perfectly mirrored arrows, drawn by
`scripts/prepare-menu-icon.swift` at 22 pt for 1×, 2× and 3× screens.

The drag-to-Applications installer artwork is drawn by
`scripts/prepare-installer-art.swift`; see `Assets/Installer/README.md`.
No stock source image is part of the public project.
