#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SOURCE="$PWD/Build/Trump Switcher.app"
DEST="/Applications/Trump Switcher.app"
codesign --verify --strict "$SOURCE"
if pgrep -x TrumpSwitcher >/dev/null; then
    echo "Quit Trump Switcher before installing an update." >&2
    exit 1
fi
if test -e "$DEST"; then
    mkdir -p Backups
    ARCHIVE="$PWD/Backups/TrumpSwitcher-installed-$(date +%Y%m%d-%H%M%S).zip"
    ditto -c -k --keepParent "$DEST" "$ARCHIVE"
    unzip -tq "$ARCHIVE"
fi
# Stage/verify the whole bundle, then replace it without stale resource files.
# A failed final verification restores the previous complete application.
python3 scripts/replace-app-bundle.py "$SOURCE" "$DEST"
REGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$REGISTER" -u "$SOURCE" || true
"$REGISTER" -f "$DEST" || true
touch "$DEST" || true
printf 'Installed: %s\n' "$DEST"
