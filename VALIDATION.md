# Trump Switcher 0.5.0 verification — 2026-10-09

Final self-contained app: `Build/Trump Switcher.app`, bundle `local.trumpswitcher.mac`.
Native GUI launch succeeded. Accessibility was restored for the final signature;
GUI diagnostics confirmed `Доступ: есть` and `Авто: подключено`.

- 1,863 core checks passed with packaged resources; 1,866 with enabled system-layout checks.
- 240 native CGEvent/NSEvent checks passed (created only, never posted).
- Exact `lkz → для`, `b → и`, `d → в`, reverse short English words, sentence punctuation,
  quote/bracket combinations, domains/URLs/email, compact dotted phrases, hyphenated words,
  English contractions, excluded tokens, rule precedence, bounded tokens and settings decoding.
- Read actual Apple Mac/PC/phonetic Russian and ABC tables, physical printable positions,
  Shift/Option/Caps combinations and Option+Space/NBSP. No system layout was changed by tests.
- `--check-offline` confirmed IPv4/IPv6 TCP/UDP operations refused by the applied named
  macOS sandbox profile; verification used loopback only. No external target, DNS or HTTP probe.
- `lsof -nP -a -c TrumpSwitcher -i` returned no IP descriptors for the running app.
- GUI forms: add/remove word and application exclusions; add/edit/remove a phrase rule.
  Exported JSON matched settings, contained no temporary test rules/exclusions; valid import
  succeeded; incomplete JSON was refused without replacing settings. Temporary files removed.
- Preferences survived app restart. Final auto, both directions, short words, punctuation,
  addresses, Enter/Tab remained enabled; CAPS conversion remains opt-in.
- Original PNG has alpha transparency: 1,385,613 fully transparent pixels of 1,572,516.
  It is packaged as a 22-pt macOS template menu-bar icon. Stock reference was not edited.
- Ad-hoc bundle signature verified strictly. Pre-change recovery ZIP verified with testzip.

Limits: these are algorithm/native event/UI checks, not proof of physical-input success in
all third-party editors. MAX/Codex compatibility is not newly certified by this run. Unknown
or ambiguous text stays; protected input, dead keys, IMEs and filtered events cannot be promised.
The named sandbox API is deprecated; failure to apply/verify it refuses app startup.

## Menu-bar icon revision — 0.5.1

Generated a bolder profile through the built-in imagegen edit tool. Original retained
as `Assets/TrumpProfile-v1.png`; final asset `Assets/TrumpProfile.png`. Compared both
alpha masks at native 24 pixels and enlarged on light/dark backgrounds. Solid opaque
coverage increased from approximately 5% to 33%; exterior/negative spaces stay transparent.
Changed image size 22 → 24 pt and status item width to 30 pt. Core correction logic,
settings and network restriction unchanged. Recovery archive verified before the change.


## Settings for ordinary users — 0.6.0

Replaced technical-first settings with four task-oriented tabs: Главная, Не менять,
Мои замены, Дополнительно. Home exposes one automatic correction control and live,
structured status (ready/off/paused/access needed/unavailable/no direction), with
relevant recovery actions. Word/application lists have empty-state guidance, disabled
removal without selection and human-readable application names. A native application
picker replaces raw bundle-ID entry. Rules infer the output language for new entries,
keep the stored language when editing, and reset the form after a successful save.
Detailed behavior/layout options remain available; diagnostic counters are in a
separate window. Menu/help text uses plain language. Existing settings schema and
keyboard/network implementation remain unchanged.

Live CUA verification: visually inspected home, all primary tabs and nested sections;
added/deleted a word exclusion and TextEdit application exclusion; created a Russian
phrase replacement, edited it to an English phrase with inferred language, reselected
it and confirmed English persisted; removed it. Toggled automatic correction off/on
and checked live home status. Exported settings before/after; JSON objects were equal,
so no test entries or changed preferences remained. Table cells are read-only; edits
use the labeled form. Required build checks: 1863 core checks in both development and
packaged-resource modes; 240 native keyboard payload checks; offline sandbox and
bundled dictionary checks; strict bundle signature verification. Recovery ZIP:
Backups/TrumpSwitcher-0.5.1-before-simple-settings.zip (integrity checked).

Final 0.6.0 launch after refreshing its existing macOS Accessibility record showed
«Готов к работе» on home. Separate diagnostic window confirmed access present,
active monitoring and registered manual shortcut. `lsof -nP -a -c TrumpSwitcher -i`
returned no IP descriptors. Before/after preferences exports were identical.


## Input latency, source transition and common names — 0.6.1

Identified synchronous 10-Hz AX focus/role polling on the keyboard tap's main run loop,
repeated TIS source list enumeration during per-character replacement planning, and
unhandled queued old-source Unicode immediately after an automatic source switch.
Moved AX reads to a serial worker, coalesced overlapping requests, batched role/protection
queries, and reject outdated results using PID/context generation. Explicit protected
metadata stays authoritative; no value/text/range attributes are read. Wrapper-only
focus identity churn no longer resets a token; actual text-field identity changes still
invalidate it and mouse/Tab resets are not repeated midway through the new token.
Source availability is warmed on startup/source changes, and actual keyboard tables are
captured once for each correction. Selection and rollback use exact source IDs.

QueuedLayoutTransition covers a 100-ms window after an own switch, requires the current
source to be the exact target and old Unicode to match physical key/modifiers, and runs
only for untagged system events with source PID 0 and a non-private event source.
Arbitrary injected/mixed text is never rewritten through this path. Separately, complete
mixed-script words can convert only to a unique full dictionary candidate; mixed code,
addresses, digits, exclusions and ambiguous candidates stay unchanged. New local
CommonNames adds explicit brand/place/person spellings and selected Russian inflections;
it has no runtime downloads or learned-input cache. Named camel-case products are allowed
without enabling general CAPS conversion. Diagnostic timing/tap interruption/reconciliation
counts contain no word contents.

Regression checks: 1948 core checks in development and packaged-resource modes, including
Яндекс/Яндекса/Яндексе, Telegram/WhatsApp/ChatGPT, correctly spelled name preservation,
RU↔EN queued next words, Shift/Caps, deadlines, manual source change, injected-text refusal,
nonprinting keys, focus wrapper changes and complete mixed-script recovery/preservation.
800 representative dictionary decisions: 8 ms in the pre-packaging run. 240 native event
checks remain required; these create/bridge events without posting. Sandbox, packaged
resources and strict signature are checked by the build. The installed macOS 27 SDK
removed legacy sandbox constant declarations, so build explicitly retains installed 26.5
SDK/native Swift build system. The network sandbox and startup refusal on failure are
unchanged. Recovery ZIP verified: Backups/TrumpSwitcher-0.6.0-before-input-latency.zip.

These checks reproduce algorithmic queue/focus cases, not the timing of every editor.
No new claim of universal physical-input compatibility is made. Unknown names, secure
fields, IMEs/dead keys and apps that ignore/filter injected events retain their limits.

During packaging, Swift 6.4's linker stamped SDK 27 despite compiling against 26.5.
The resulting binary was terminated by macOS's SANDBOX namespace before GUI startup
when using the unchanged legacy sandbox profile. Explicit matching platform/SDK linker
flags produced LC_BUILD_VERSION minos 13.0 / sdk 26.5. The packaged app then passed
IPv4/IPv6 TCP/UDP denial (loopback only), dictionary and 240 native-event checks.
Executable replacement also uses a new inode before ad-hoc signing. Network protection
was never disabled or replaced with an unrestricted launch.

Final 0.6.1 packaged build passed all 1948 core checks, 240 native event checks,
resource/signature checks and startup loopback-only network denial. Existing Accessibility
permission was refreshed through System Settings after the user's local authentication.
Live diagnostic UI showed access present, auto connected, hotkey registered, 41 events,
zero tap interruptions, callback maximum rounded below 1 ms and background focus maximum
13 ms. This is idle/UI-event evidence, not a physical typing/correction benchmark.
`lsof -nP -a -c TrumpSwitcher -i` returned no IP descriptors. User preferences were not
changed by this update. Built-in vocabulary has no runtime external connections.
