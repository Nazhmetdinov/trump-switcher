# Trump Switcher artwork

The app icon is a new illustration generated independently for this project.
`TrumpAppIcon-original-generated.png` is the local source. The deterministic
AppKit script `scripts/prepare-app-icon.swift` crops and masks it to a clean
rounded tile at larger sizes and draws a simplified portrait at 16–64 pixels.
`scripts/pack-app-icon.py` packs the two smallest 1× representations as native
ARGB and the larger/Retina representations as PNG into `TrumpAppIcon.icns`.
This keeps small icons legible in macOS permission lists and avoids the colour
noise macOS displays for PNG payloads under the legacy `icp4`/`icp5` tags.

The menu-bar icon is a compact A | Я mark with a fine vertical separator,
drawn by `scripts/prepare-menu-icon.swift` at 22 pt for 1×, 2× and 3× screens.

The drag-to-Applications installer artwork is drawn by
`scripts/prepare-installer-art.swift`; see `Assets/Installer/README.md`.
No stock source image is part of the public project.
