#!/bin/bash
# Cross-compile the current release for Intel without replacing the Apple Silicon app.
set -euo pipefail
cd "$(dirname "$0")/.."
SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
test -d "$SDK"
BASE_APP="$PWD/Build/Trump Switcher.app"
test -s "$BASE_APP/Contents/Info.plist"
codesign --verify --strict "$BASE_APP"
export CLANG_MODULE_CACHE_PATH="$PWD/.build-intel/clang-cache"
swift build --build-system native --scratch-path .build-intel \
    --triple x86_64-apple-macosx13.0 --sdk "$SDK" \
    -Xlinker -platform_version -Xlinker macos -Xlinker 13.0 -Xlinker 26.5 \
    --disable-sandbox -c release --product TrumpSwitcher
BINARY="$PWD/.build-intel/x86_64-apple-macosx/release/TrumpSwitcher"
test "$(lipo -archs "$BINARY")" = x86_64
STAGE="$(mktemp -d "$PWD/Build/.intel-package-XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Trump Switcher.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BINARY" "$APP/Contents/MacOS/TrumpSwitcher"
cp "$BASE_APP/Contents/Info.plist" "$APP/Contents/Info.plist"
python3 scripts/package-resources.py "$APP"
codesign --force --sign - "$APP"
python3 scripts/check-release-package.py "$APP" x86_64
FINAL_APP="$PWD/Build/Intel/Trump Switcher.app"
mkdir -p "$(dirname "$FINAL_APP")"
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
printf 'Built Intel app: %s\n' "$FINAL_APP"
