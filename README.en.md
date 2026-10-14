<p align="center"><img src="Assets/TrumpAppIcon.iconset/icon_128x128@2x.png" width="112" alt="Trump Switcher icon"></p>
<h1 align="center">Trump Switcher</h1>
<p align="center">Local Russian ↔ English keyboard-layout correction for macOS</p>
<p align="center"><a href="README.md">Русский</a> · <a href="https://github.com/Nazhmetdinov/trump-switcher/releases/latest">Download</a> · <a href="CHANGELOG.md">Changelog</a> · <a href="THIRD_PARTY.md">Dictionary licenses</a></p>

Trump Switcher corrects a word typed in the wrong keyboard layout. Type `ghbdtn` and a space to get `привет`; `руддщ` becomes `hello`. It lives in the menu bar and needs no account.

## Highlights

- **Stays on your Mac.** Dictionaries are bundled. The app applies an operating-system network restriction at startup and does not keep a typing history.
- **Works in both directions.** Russian ↔ English correction considers short words, mixed-script tokens, punctuation and address-like text. Ambiguous input stays untouched.
- **Your rules.** Add replacements and exclusions, pause automatic correction, or convert a selection manually in the settings UI.
- **Your choice.** Optional launch at login, with no account, telemetry, cloud dictionary or auto-download.
- **Inspectable.** Source code and dictionary provenance are public.

Correction normally runs after Space; Enter and Tab are configurable boundaries. Unambiguous punctuation can trigger it immediately. Examples: `lkz` → `для`, `b` → `и`, `ghbdtn!` → `привет!`.

## Install

1. Download the [latest DMG](https://github.com/Nazhmetdinov/trump-switcher/releases/latest) for **Apple Silicon (M1 or newer)** and **macOS 13+**.
2. Open the image and drag **Trump Switcher** onto **Applications**.
3. Start it from Applications and grant **Accessibility** permission when macOS asks. This permits the app to inspect the current word and type its correction.
4. Open settings from the menu bar icon; launch at login is optional.

The build is locally signed and **not Apple-notarized** yet. macOS may show an unidentified-developer warning on first launch. Use the standard system **Open** action for software you trust; the installer never changes security settings automatically.

## Privacy and limits

At startup the app applies the macOS `kSBXProfileNoInternet` sandbox profile and verifies that network sockets are denied. It refuses to start if that check fails. The current token exists briefly in memory for correction; the app has no typing log or upload path. Password fields and Secure Input are excluded. See [SECURITY.md](SECURITY.md).

Behavior depends on the focused editor and macOS Accessibility permission. IME composition, protected fields and applications that reject synthesized keyboard events may not be supported. The project cannot promise correction in every application. Ambiguous words are intentionally left as typed.

This is an **unofficial project** with no affiliation to Donald Trump, his organizations, Yandex or Punto Switcher. No Punto Switcher code or proprietary dictionary is included.

## Source and build

The code uses Swift, C and C++. The current build recipe requires macOS SDK **26.5** and Swift **6.4**. Hunspell sources and offline dictionaries are included; builds do not fetch packages over the network.

```bash
bash scripts/build.sh
```

Packaging needs the build-only tools in `scripts/installer-requirements.txt`:

```bash
DMGBUILD_PYTHON=/path/to/packaging/python bash scripts/package-release.sh
```

The app is written to `Build/`; DMG and ZIP archives go to `Releases/`. `scripts/build.sh` runs the local checks. See [VALIDATION.md](VALIDATION.md) for their scope and limitations.

Original project code and documentation are [MIT-licensed](LICENSE). Dictionaries, Hunspell and adapted portions retain their separate terms and notices in [THIRD_PARTY.md](THIRD_PARTY.md). The new project icon is generated from independent local artwork; no stock image is distributed.

When opening an [issue](https://github.com/Nazhmetdinov/trump-switcher/issues), use synthetic example text and include the macOS version and editor name. Never post private messages or credentials.
