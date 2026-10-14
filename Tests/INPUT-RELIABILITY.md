# Input reliability regression report — 0.6.3 (18)

## Reproduced defects

- `Control+Space` was treated as a destructive shortcut. Modifier-only events
  discarded the buffer even before the shortcut was identified. The next complete
  word could consequently be ignored until another space.
- `Cmd+A` (with or without Delete) left tracking unarmed for the replacement word.
- Scroll events erased an unfinished word even though the caret did not move.
- A first key that beat a background focus check was dropped with the entire word.
  New focus now gets one bounded metadata check in that case; an older asynchronous
  result cannot overwrite it. Secure input and excluded fields remain blocked.
- `@ghbdtn@`, `руддщЖ`, `ЭруддщЭ`, words containing Mac `ё`, and trailing dashes
  were rejected by symbol/capital checks before their converted spelling was parsed.
- `'nj` and `'njn` (это / этот) competed with an unmatched quote plus то / тот.
  Mixed wrappers such as `('nj)` needed independent parsing of the two edges.
- Automatic processing previously waited for Space/Enter/Tab even after an
  unambiguous punctuation boundary. It now replaces the preceding token and that
  punctuation before allowing later keys through the same event stream.

## Validation

- Before the punctuation fix: 26 differences/skips in 121 physical-key fixtures
  for Apple's Russian-Mac layout. Those 121 now pass; a broader regression matrix
  includes additional words, ё, dash variants, and checks preserving correct text.
- 2467 core checks pass, including scratch-editor replay of physical multiword
  sequences. Replay applies the actual deletion/typing plans and checks that the
  intercepted punctuation causes no extra deletion, space, or missing character.
- The build separately checks generated native key-down/key-up events, packaged
  dictionaries, strict code signing, and the process's network-denial profile.
- These deterministic checks do not establish global-hook delivery in every
  third-party editor. UI/native-typing observations are recorded separately below.

## Punctuation intent

Literal punctuation is kept when alternatives disagree only on that punctuation.
For example, on Russian-PC the same key can mean a visible `?` or an intended `,`.
A purely physical round-trip therefore differs from this policy in 15 of the 121
Russian-PC audit fixtures. This is an intent ambiguity, not a dictionary lookup.
Whole-word ambiguity such as `levf.` (думаю / дума.) remains unresolved automatically.
Users can define explicit replacements for ambiguous tokens.

Comma/period/quote keys mapping to letters remain in the current token so that
`hf,jnftn` is not cut at the б key. Space, Enter or Tab finishes those tokens.
Address and URL punctuation is also kept until a complete boundary.

## Upstream research

- Punto's official Mac page documents automatic switching and user replacements:
  https://yandex.ru/soft/punto/mac/
- Official 2.1 release notes mention updated auto-switch rules, but provide no
  reusable implementation: https://yandex.ru/project/set/punto/release/mac/0
- Bzz's MIT-licensed boundary/punctuation classification was adapted to Swift
  and real Apple tables. Revision: b36c1c87d2fcafd82617686df74f0e74092d7ff4.
  https://github.com/zlopixatel/bzz/blob/b36c1c87d2fcafd82617686df74f0e74092d7ff4/buffer.go
  https://github.com/zlopixatel/bzz/blob/b36c1c87d2fcafd82617686df74f0e74092d7ff4/detector.go
  Attribution/license are in THIRD_PARTY.md and the bundled MIT notice.

No external connection is introduced into Trump Switcher. Research downloads are
build-time investigation only. No typed words, history, clipboard contents or
remote dictionary services are used by these changes. Diagnostic counters contain
counts and reason categories, not user text.

## Running application check

Version 0.6.3 (18) was built and launched. Accessibility was renewed for the same
application and scope; the home screen shows «Готов к работе». Live diagnostics
confirm the global filter is connected, with no tap interruptions at startup.
The packaged build passes all 2467 core checks and 240 native-event checks, as
well as network denial and strict signature checks.

A separate blank TextEdit document was used for a CUA keystroke test. Its visible
text became «Привет », but the global filter recorded no corresponding character
sequence and zero automatic corrections. This is NOT evidence of automatic
switching: the UI tool delivered keys directly to the background window in the
active Russian layout, bypassing the global tap. A physical-typing confirmation
was requested separately; no success claim for all applications is inferred from
this test.
