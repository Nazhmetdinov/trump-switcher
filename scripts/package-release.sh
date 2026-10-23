#!/bin/bash
# Produce a branded drag-to-Applications disk image without opening Finder.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:-$PWD/Build/Trump Switcher.app}"
TARGET_ARCH="${TRUMP_ARCH:-arm64}"
case "$TARGET_ARCH" in
    arm64) RELEASE_ARCH="AppleSilicon"; PLATFORM_DESCRIPTION="Apple Silicon (M1 и новее)"; VOLUME_NAME="Trump Switcher" ;;
    x86_64) RELEASE_ARCH="Intel"; PLATFORM_DESCRIPTION="Intel (x86_64)"; VOLUME_NAME="Trump Switcher Intel" ;;
    *) echo "Unsupported architecture: $TARGET_ARCH" >&2; exit 1 ;;
esac
ARTWORK_DIR="$PWD/Assets/Installer"
if [[ "$TARGET_ARCH" == x86_64 ]]; then ARTWORK_DIR="$PWD/Assets/InstallerIntel"; fi
DMGBUILD_PYTHON="${DMGBUILD_PYTHON:-python3}"
"$DMGBUILD_PYTHON" -c 'import dmgbuild, ds_store, mac_alias' || {
    echo 'Install the build-only tools from scripts/installer-requirements.txt in your packaging Python.' >&2
    exit 1
}
test -s "$ARTWORK_DIR/background.tiff"
codesign --verify --strict "$APP"
test "$(lipo -archs "$APP/Contents/MacOS/TrumpSwitcher")" = "$TARGET_ARCH"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
# Finder records the background against the mounted volume path. Give each
# release its own name so an older mounted installer cannot redirect that path.
VOLUME_NAME="$VOLUME_NAME $APP_VERSION"
RELEASE_NAME="TrumpSwitcher-${APP_VERSION}-build${APP_BUILD}-${RELEASE_ARCH}"
INSTALLER_NAME="$RELEASE_NAME"
mkdir -p Releases
RELEASE_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/trumpswitcher-release-XXXXXX")"
trap 'rm -rf "$RELEASE_STAGE"' EXIT
PAYLOAD="$RELEASE_STAGE/payload"
mkdir -p "$PAYLOAD"
ditto "$APP" "$PAYLOAD/Trump Switcher.app"
codesign --verify --strict "$PAYLOAD/Trump Switcher.app"
cp 'Assets/Installer/Настройки безопасности.url' "$PAYLOAD/Настройки безопасности.url"
swift -module-cache-path "$PWD/.build/installer-module-cache" \
    scripts/prepare-installer-shortcut.swift "$PAYLOAD/Настройки безопасности.url"
cat > "$PAYLOAD/Установка.txt" <<TEXT
Trump Switcher — установка

Для Mac с ${PLATFORM_DESCRIPTION}, macOS 13 или новее.

1. Завершите запущенный Trump Switcher через меню его значка наверху.
2. Перетащите Trump Switcher в папку «Программы» рядом.
   Если старая версия уже установлена, подтвердите замену приложения.
3. Запустите Trump Switcher из папки «Программы».
4. Если macOS блокирует запуск непроверенного приложения, откройте ярлык
   «Настройки безопасности» в этом образе. Если вы доверяете скачанной копии,
   нажмите «Всё равно открыть» для Trump Switcher и подтвердите запуск.
5. Если программа просит доступ, нажмите её кнопку разрешений macOS и
   включите Trump Switcher в открывшемся системном списке. После обновления
   macOS может потребовать заново добавить приложение в этот список.

6. В macOS → Клавиатура → Ввод текста должны быть добавлены русская
   раскладка (обычная, ПК или фонетическая) и ABC/США.
   Если одной из них нет, приложение покажет подсказку.

Ваши обычные настройки, исключения и замены сохраняются отдельно от программы.
Автозапуск включается в меню значка или в настройках → «Дополнительно».

Программа работает локально. Сетевые подключения запрещены; история набора
не записывается. Встроенные словари, лицензии и исходники Hunspell находятся
внутри приложения. Самостоятельной загрузки обновлений нет.

Сборка подписана локально (ad hoc); Apple-нотариализация не выполнялась.
Поэтому macOS может предупредить о непроверенном разработчике при запуске.
Никакие настройки безопасности установочный образ самостоятельно не меняет.
TEXT
"$DMGBUILD_PYTHON" -m dmgbuild -s scripts/installer-settings.py \
    -D "root=$PWD" \
    -D "artwork=$ARTWORK_DIR" \
    -D "app=$PAYLOAD/Trump Switcher.app" \
    -D "instructions=$PAYLOAD/Установка.txt" \
    -D "security_shortcut=$PAYLOAD/Настройки безопасности.url" \
    "$VOLUME_NAME" "$RELEASE_STAGE/$INSTALLER_NAME.dmg"
hdiutil verify "$RELEASE_STAGE/$INSTALLER_NAME.dmg"
"$DMGBUILD_PYTHON" scripts/check-installer-layout.py \
    "$RELEASE_STAGE/$INSTALLER_NAME.dmg" "$APP" "$ARTWORK_DIR"
if [[ "${TRUMP_DMG_ONLY:-0}" == 1 ]]; then
    # Re-style an existing release without changing its verified app archive.
    test -s "Releases/$RELEASE_NAME.zip"
    unzip -tq "Releases/$RELEASE_NAME.zip"
else
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$RELEASE_STAGE/$RELEASE_NAME.zip"
    unzip -tq "$RELEASE_STAGE/$RELEASE_NAME.zip"
fi
mv -f "$RELEASE_STAGE/$INSTALLER_NAME.dmg" "Releases/$INSTALLER_NAME.dmg"
if [[ "${TRUMP_DMG_ONLY:-0}" != 1 ]]; then
    mv -f "$RELEASE_STAGE/$RELEASE_NAME.zip" "Releases/$RELEASE_NAME.zip"
fi
(
    cd Releases
    shasum -a 256 "$INSTALLER_NAME.dmg" > "$INSTALLER_NAME.sha256"
)
printf 'Installer: %s/Releases/%s.dmg\n' "$PWD" "$INSTALLER_NAME"
