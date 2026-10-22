# Third-party components in Trump Switcher

All dictionaries are bundled locally; no runtime downloading or automatic updates.
Exact revisions and SHA-256 hashes are in `Dictionaries/provenance.json`.

## LibreOffice dictionaries (unchanged data)

https://github.com/LibreOffice/dictionaries at
`32b006a2c22a4ac7e8ed3f03346f7b3d85a970a4`.

- `ru_RU.aff`, `ru_RU.dic`: Copyright 1997–2008 Alexander I. Lebedev,
  with upstream changes by Laszlo Nemeth. Redistribution conditions and disclaimer
  are reproduced in `Dictionaries/README_ru_RU.txt`.
- `en_US.aff`, `en_US.dic`: SCOWL/Ispell-derived English dictionary.
  Full copyright notices, permissions, source credits and disclaimers are
  reproduced in `Dictionaries/README_en_US.txt`.
- `en_GB.aff`, `en_GB.dic`: British English by Kevin Atkinson, David Bartlett,
  Brian Kelk, Andrew Brown and Marco A.G.Pinto, LGPL as specified by upstream.
  Unchanged editable dictionary/affix sources and `README_en_GB.txt` are bundled.
  Upstream license text and LGPL 2.1 are in `Dictionaries/Licenses/EnglishGB/`.

## Supplementary Russian dictionary (MPL 2.0)

https://github.com/Goudron/ru-spelling-dictionary at
`0f983e6b1950e240f5512974a5f146ea56f64bed`, release 1.0.9.
Copyright (c) 2026 Valery Ledovskoy. The original KOI8-R affix/dictionary data
are unchanged, renamed `ru_modern.aff` / `ru_modern.dic` to coexist with the base
dictionary. Queries are converted to KOI8-R in memory. The full editable sources
are included in the app; the copyright notice, upstream README and MPL 2.0 text
are in `Dictionaries/Licenses/RussianModern/`. Hashes are pinned in provenance.json.
Runtime lexical filtering does not modify these source files.

## Hunspell 1.7.2

https://github.com/hunspell/hunspell/tree/v1.7.2

Hunspell/MySpell copyright and contributor notices are retained in every source
file and in `Dictionaries/Licenses/Hunspell/`. Trump Switcher uses the MPL 1.1 option
of the upstream MPL/GPL/LGPL tri-license. The MPL-covered source code, generated
static-build header, forwarding headers, license texts and the SwiftPM build
configuration are provided in `Dictionaries/Licenses/Hunspell/Source.zip` inside
the application. Source is also present in this project's `Sources/Hunspell`.
Generated/forwarding headers are marked; other engine source is unchanged.
No additional restriction is imposed on rights granted by the MPL.

## FrequencyWords data

FrequencyWords by **Hermit Dave**, derived from **OpenSubtitles 2018**:
https://github.com/hermitdave/FrequencyWords
http://opus.nlpl.eu/OpenSubtitles2018.php

Data license: **Creative Commons Attribution–ShareAlike 4.0 International**:
https://creativecommons.org/licenses/by-sa/4.0/
The upstream repository's MIT license applies to its code, not these data.

The word packs were prepared by **RuSwitcher contributors**:
https://github.com/rashn/RuSwitcher at
`2ee0bc70ec9ea1e1455246cdbd54708532a61122`.
Their changes: lowercase words of at least three letters, top 50,000 Russian and
30,000 English words, sorted and compressed. Trump Switcher expands raw deflate
to UTF-8 text; the word lists are otherwise unchanged. These word-list files
remain under CC BY-SA 4.0. Original attribution, manifest and license links,
and the complete CC BY-SA license text are in `Dictionaries/Licenses/FrequencyWords`.
Upstream compressed pack hashes were verified before importing.

No code or dictionaries from Punto Switcher are included.

## RuSwitcher recognition protections (MIT)

`Sources/SwitcherCore/ShortSourceProtection.swift` adapts the short-token
collision guards from `macos/Sources/RuSwitcher/ShortWords.swift` at
https://github.com/rashn/RuSwitcher/tree/436061c7fe7839ea52b1a5b4776c13611a868ddb.
`AutoCorrection.swift` adapts the two-sided exclusion policy from
`AutoSwitchPolicy.isDeniedWord` in `AutoSwitch.swift` at the same revision.
Copyright (c) 2025 Rashns. The full MIT notice is bundled at
`Dictionaries/Licenses/RuSwitcher/LICENSE`.

Changes: short English collision spellings protect uppercase abbreviations or
a source established by a preceding known English word. Language context stores
only the language and resets on focus/manual-source changes; lowercase isolated
Russian function words remain eligible. Target exclusions are checked after the
complete candidate is selected, preserving this project's punctuation and
ambiguity decisions, explicit-rule precedence, and physical layout conversion.
No upstream event-injection implementation, system-spelling dependency, remote
desktop handling, telemetry, or update code is included.

## Bzz boundary classification (MIT)

`Sources/SwitcherCore/WordBoundary.swift` adapts Bzz's distinction between word
boundaries and punctuation keys that represent letters on another layout:
https://github.com/zlopixatel/bzz/blob/b36c1c87d2fcafd82617686df74f0e74092d7ff4/buffer.go
and the trailing-punctuation cases in `detector.go` at the same revision.
Copyright (c) 2026 Roman Kovalev. The MIT notice is bundled at
`Dictionaries/Licenses/Bzz/LICENSE`.

The Swift implementation reads actual Apple layout tables and preserves address
tokens. No Bzz executable, clipboard code, input logging, fuzzy spelling changes
or network functionality is included.

## IANA delegated top-level domain names

`iana_tlds.txt` is an unchanged snapshot of the factual root-zone name list from
https://data.iana.org/TLD/tlds-alpha-by-domain.txt, version 2026100900 (2026-10-09).
The source URL, original version header and SHA-256 are preserved. The list is
used only to recognize address syntax offline, with no DNS or HTTP lookups.
No IANA website prose or third-party protocol-registry licensing claims are included.
