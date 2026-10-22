#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
# The 27 SDK removed the legacy named sandbox constants; retain the installed
# 26.5 SDK while the same runtime profile remains guarded by a startup check.
SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
test -d "$SDK"
swift -sdk "$SDK" -module-cache-path .build/icon-module-cache scripts/prepare-menu-icon.swift "$PWD"
# Recreate the public icon from independent local source artwork.
swift -sdk "$SDK" -module-cache-path .build/app-icon-module-cache scripts/prepare-app-icon.swift "$PWD"
python3 scripts/pack-app-icon.py Assets/TrumpAppIcon.iconset Assets/TrumpAppIcon.icns
test -s Assets/TrumpAppIcon.icns
# Swift 6.4 otherwise stamps the current SDK into the binary despite --sdk.
# The linked-on version must match the SDK actually used to compile this app.
swift build --build-system native --sdk "$SDK" -Xlinker -platform_version -Xlinker macos -Xlinker 13.0 -Xlinker 26.5 --disable-sandbox -c release --product TrumpSwitcher
swift run --build-system native --sdk "$SDK" -Xlinker -platform_version -Xlinker macos -Xlinker 13.0 -Xlinker 26.5 --disable-sandbox -c release CoreChecks
swiftc -sdk "$SDK" -module-cache-path .build/ellipsis-policy-cache Sources/SwitcherCore/EllipsisBoundary.swift scripts/check-ellipsis-policy.swift -o .build/ellipsis-policy-checks
.build/ellipsis-policy-checks
swiftc -O -target "$(uname -m)-apple-macosx13.0" -sdk "$SDK" -module-cache-path .build/queue-model-cache -Xlinker -platform_version -Xlinker macos -Xlinker 13.0 -Xlinker 26.5 Sources/SwitcherCore/InputDeliveryQueue.swift Sources/SwitcherCore/OrderedInputCancellation.swift Sources/SwitcherCore/EllipsisBoundary.swift scripts/check-input-queue-model.swift -o .build/input-queue-model-checks
.build/input-queue-model-checks
swiftc -O -target "$(uname -m)-apple-macosx13.0" -sdk "$SDK" -module-cache-path .build/input-plan-cache -Xlinker -platform_version -Xlinker macos -Xlinker 13.0 -Xlinker 26.5 Sources/TrumpSwitcher/InputPipelineEventPlan.swift scripts/check-input-pipeline-event-plan.swift -o .build/input-pipeline-event-plan-checks
.build/input-pipeline-event-plan-checks
swiftc -parse-as-library -O -target "$(uname -m)-apple-macosx13.0" -sdk "$SDK" -module-cache-path .build/native-space-cache -Xlinker -platform_version -Xlinker macos -Xlinker 13.0 -Xlinker 26.5 scripts/check-native-space-autorepeat.swift -o .build/native-space-autorepeat-checks
.build/native-space-autorepeat-checks
mkdir -p "$PWD/Build"
PACKAGE_STAGE="$(mktemp -d "$PWD/Build/.package-XXXXXX")"
trap 'rm -rf "$PACKAGE_STAGE"' EXIT
APP="$PACKAGE_STAGE/Trump Switcher.app"
mkdir -p "$APP/Contents/MacOS"
# Use a new inode when replacing an executable; do not rewrite cached signed pages.
cp .build/release/TrumpSwitcher "$APP/Contents/MacOS/TrumpSwitcher.new"
mv -f "$APP/Contents/MacOS/TrumpSwitcher.new" "$APP/Contents/MacOS/TrumpSwitcher"
python3 scripts/package-resources.py "$APP"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>TrumpSwitcher</string>
<key>CFBundleIdentifier</key><string>local.trumpswitcher.mac</string>
<key>CFBundleName</key><string>Trump Switcher</string>
<key>CFBundleIconFile</key><string>TrumpAppIcon.icns</string>
<key>CFBundleDisplayName</key><string>Trump Switcher</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.6.43</string>
<key>CFBundleVersion</key><string>82</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
.build/release/CoreChecks --dictionary-directory "$APP/Contents/Resources/Dictionaries"
"$APP/Contents/MacOS/TrumpSwitcher" --check-offline
"$APP/Contents/MacOS/TrumpSwitcher" --check-dictionaries
"$APP/Contents/MacOS/TrumpSwitcher" --check-keyboard-events
"$APP/Contents/MacOS/TrumpSwitcher" --check-editor-replacements
"$APP/Contents/MacOS/TrumpSwitcher" --check-application-configuration
python3 scripts/check-app-installer.py
python3 scripts/check-release-package.py "$APP"
FINAL_APP="$PWD/Build/Trump Switcher.app"
# Publish only a fully checked, fresh bundle. Reuse the tested rollback logic;
# this replaces the build artifact, never /Applications or the running app.
python3 - "$APP" "$FINAL_APP" <<'PY'
import runpy
import subprocess
import sys
replace = runpy.run_path("scripts/replace-app-bundle.py", run_name="build_publish")["replace_bundle"]
def copy(source, destination):
    subprocess.run(["/usr/bin/ditto", str(source), str(destination)], check=True)
def verify(path):
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(path)], check=True)
replace(sys.argv[1], sys.argv[2], copy, verify)
PY
APP="$FINAL_APP"
printf 'Built: %s\n' "$APP"
