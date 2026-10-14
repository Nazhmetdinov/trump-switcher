#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
swift build --build-system native --sdk "$SDK" -Xlinker -platform_version -Xlinker macos -Xlinker 13.0 -Xlinker 26.5 --disable-sandbox -c release --product InputFixture
APP="$PWD/Build/InputFixture.app"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/InputFixture "$APP/Contents/MacOS/InputFixture.new"
mv "$APP/Contents/MacOS/InputFixture.new" "$APP/Contents/MacOS/InputFixture"
python3 - <<'PY'
import plistlib
from pathlib import Path
Path('Build/InputFixture.app/Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleExecutable': 'InputFixture',
    'CFBundleIdentifier': 'local.trumpswitcher.input-fixture',
    'CFBundleName': 'Trump Switcher Input Fixture',
    'CFBundlePackageType': 'APPL',
    'LSMinimumSystemVersion': '13.0',
    'NSHighResolutionCapable': True,
}))
PY
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
