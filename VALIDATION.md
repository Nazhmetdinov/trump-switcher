# Trump Switcher verification

## 0.6.52 · build 91: Russian-primary recognition — 2026-10-30

ARM64 release packaging, signature, 240 native-event, 182 in-process editor,
721 configuration checks and 8 installer rollback tests passed. Installed bundle
binary SHA-256: `a735feb1114f8dbf39d09f1afea348fb2636d11013c7dd4cbb8a48b412f6f8ef`.
Russian-primary persistence and the installed app's ready status were verified
after permission renewal. Intel
cross-compilation, architecture/resource/signature checks also passed
(`Build/russian-priority-intel.log`); Intel runtime was not tested.

Added an optional persisted Russian-primary flag and an Advanced checkbox. Old
settings decode absent flag as off; malformed values are rejected. With the flag
on, isolated uppercase Latin keys whose Russian mapping is a known one-letter
function word are eligible. Real source words (including a/I), English context,
source/target exclusions, user rules and disabled directions retain precedence.
No statistics/history of the user's text is stored or transmitted.

A new mixed-source sequence regression found `таймве,` was skipped: the parser
stripped the final comma before deciding whether Cyrillic input still contained
an English letter key. Detection now inspects the original token for these keys;
full candidate recognition and valid-source preservation remain mandatory. No
focus checks, queue deadlines or transport ordering were relaxed.

Added 165 unique locally authored spellings to the reviewed corpus (72 names,
39 brand-related terms, 54 colloquial forms). Existing complete-corpus checks
cover those additions, including alphabet, case, physical conversion, source
collisions, punctuation and target exclusions. New tests enumerate every split
position for mixed-language tokens in both directions at an 8 ms modeled key
interval; no events are sent to editors. Mode persistence, negative cases and
settings disable paths are exercised too.

504,483 core assertions passed, including 1,019 Russian-priority/sequence checks.
`Build/russian-priority-core.log`, `Build/russian-priority-release.log` contain
results. This is offline validation, not proof of zero missed edits under real
editor load. An unknown English token is still not sufficient on its own to
justify rewriting it as Russian.

Release CoreChecks `--benchmark-russian-priority`: 16 tokens, 1,600 warmed decisions
per mode on this Mac. Off p50/p95/max: 0.0152/0.0616/0.0773 ms; on:
0.0157/0.0622/0.1045 ms. These samples isolate the mode's detector cost, not the OS
or editor. No timing threshold is asserted. Log: `Build/russian-priority-performance.log`.

## 0.6.51 · build 90: short-word recovery — 2026-10-27

Read only the installed app's settings and text-free diagnostic counters. Version
0.6.49 had both directions and short words enabled, no custom rules or exclusions.
The current session included rejected focus keys, unverified editor reads and one
continued-typing timeout. These counters do not identify the exact user's words;
empty-boundary counts include ordinary repeated separators.

The dictionary already recognizes lower-case `f/d/r` as `а/в/к`. Found a separate
stream-state defect: destination originals returned after cancellation did not
update word-boundary provenance (session-routed originals did). The buffer stayed
invalid after a returned Space, skipping the following complete word. Also,
metadata rejection preserved an empty boundary in FocusPermission but the ensuing
cancel() immediately invalidated it again. Rejected Space itself also invalidated
rather than ended the partial token.

Fixed all three paths. Destination tracking is restricted to the tracked, current
PID; it never detects/corrects flushed text. Any flushed non-boundary character
still invalidates partial-word tracking. A plain known boundary does not authorize
an edit: focus, selection, text and routing checks still apply. Cancellation now
resets its buffer before flushing so replayed boundary observations survive.

Added 949 assertions covering actual OrderedInputCancellation ownership and the
production CancelledInputBoundary observer, blocked letters vs separators, late
focus recovery, all supported physical layout pairs, both language contexts,
short-word disable settings and preservation of legitimate source words. Existing
uppercase-initial and English abbreviation protections remain unchanged.
480,199 core assertions, 240 native-event checks, 182 in-process editor checks,
717 configuration checks and 8 installer rollback tests passed in the final
ARM64 release build. Signed package verification passed; binary SHA-256:
`d8fcd5fae6e0448e469e51fd451cc50a3b74fa0d7a37dc18fd54f85857bfe710`.
No third-party text was read or entered. Native live delivery is not certified by
these offline tests. Log: `Build/short-word-release-final.log`.
Installed 0.6.51 after verifying backup `Backups/TrumpSwitcher-installed-20261027-154954.zip`;
macOS permission renewal completed after user authentication. System Settings
shows Trump Switcher enabled, and the installed app shows «Готов к работе».
Intel cross-build, architecture, resources and signature also passed
(`Build/short-word-intel.log`); Intel runtime was not exercised.

## 0.6.50 · build 89: typing-path performance — 2026-10-23

Audited event receipt, detector, queued replay, delivery acknowledgement and focus
reads. Changes retain correction decisions and ownership checks:

- Exact user replacement rules are compiled once per settings update. The index
  preserves first-valid-rule priority, case, disabled directions, recursive
  punctuation handling and source/target exclusions.
- FIFO storage is circular rather than shifting the remaining array for each
  event. Replay yields after at most 32 events and resumes behind the final ACK;
  queued events still have one owner and retain arrival order on cancellation.
- A coalesced delivery watchdog replaces per-event timer closures. Later fences
  update its deadline; stale wakes reschedule instead of expiring the new fence.
  The existing 750 ms delivery deadline remains unchanged.
- App exclusions cache the last bundle-ID result, invalidated by settings changes.
  Selected-source changes no longer reload the enabled-source catalogue; startup
  and enabled-source notifications still refresh it.

479,250 core assertions passed, including 95,809 new regression assertions against
an independent FIFO oracle and the previous linear rule implementation. Capacity
1/2/3/32/256/1024, wrapping, cancellation, copy semantics, duplicate commits and
10,000 consecutive watchdog arms were exercised. Standard release checks also
passed: 240 native-event, 182 in-process editor, 717 configuration and 8 installer
rollback tests, plus the existing queue/punctuation models and package checks.
No input was sent to third-party applications. Logs: `Build/performance-release.log`
and `Build/input-performance.log`.

Reproducible benchmark: release `CoreChecks --benchmark-input-performance`, bundled
dictionaries, 12-token corpus, 120 timed decisions after warmup per configuration,
5,000 exact and 500 pattern exclusions. Wall-clock CPU-path samples on this ARM
Mac, not end-to-end event delivery; no threshold assertions or speed guarantee:

| User rules | Path | p50 (ms) | p95 (ms) | Maximum (ms) |
| --- | --- | ---: | ---: | ---: |
| 0 | Previous linear lookup | 0.0289 | 0.2867 | 0.3047 |
| 0 | Indexed lookup | 0.0281 | 0.2868 | 0.3100 |
| 1,000 | Previous linear lookup | 0.5668 | 13.3890 | 13.6433 |
| 1,000 | Indexed lookup | 0.0281 | 0.2786 | 0.3495 |

Results agree for the complete benchmark corpus. The largest measured improvement
requires many user rules; the default no-rule detector is effectively unchanged.
The first key in an unverified field still has a bounded metadata read (25 ms
budget), and final replacement revalidates ownership. Already-posted events still
wait for transport acknowledgement. Those safeguards and OS scheduling mean this
is not a claim of zero latency or proof that every reported live stall is resolved.

ARM64 build and local runtime checks passed. The Intel bundle cross-compiled and
passed architecture, resource and signature checks (`Build/performance-intel.log`);
Intel runtime was not exercised on this ARM Mac. The toolchain emitted its existing
missing-x86_64 compatibility-pack warning; this is not an Intel runtime validation.

The installed 0.6.49 permission was restored separately. This 0.6.50 build is local;
it was not installed or published during this audit.

## 0.6.49 · build 88: bounded waiting during continued typing — 2026-10-23

Code inspection found that a pending read-only replacement could retain subsequent
physical keys for the full 750 ms editor grace (1 s decision watchdog). Added a
120 ms decision budget starting with the first queued keyDown; subsequent keys
do not extend it. A replayed boundary with a queued keyDown arms the same budget.
KeyUp/modifiers alone preserve the previous idle-editor grace. Timeout uses the
existing ordered cancellation path, without replaying committed edits. Results
arriving after the deadline are rejected even when their callback precedes the
timer; the deadline is also checked before input-source selection and final commit.

This limits waiting BEFORE a replacement is committed, not OS scheduling latency
or transport acknowledgement of already-posted input. When the editor is too
slow, the original word is preserved without correction. No field identity,
selection or text-verification check was removed. A text-free diagnostic counter
records these cancellations.

383,441 core assertions passed, including 5,966 new budget/ownership checks.
Burst sizes 2/20/200/1000 exercise direct and replay-transferred boundaries and
both timeout/result callback orders against an arrival-order oracle. Native-event
(240), in-process editor (182), configuration (717), queue models and installer
rollback (8) checks passed in the standard release build. No third-party editor
or physical typing test was performed; this does not prove the sole cause of the
reported real-world stalls. Log: `Build/typing-latency-release.log`.

## 0.6.48 · build 87 release verification — 2026-10-23

The two development stages below are included together in this release.
A fresh native release bundle passed **377,475 core assertions**, **240 native
keyboard-event checks**, **182 in-process editor checks**, **717 application
configuration checks**, queue/punctuation models and **8 installer rollback tests**.
Packaged resources, licenses, version/build, deployment target and ad-hoc signature
were verified. The Intel bundle was cross-compiled and its x86_64 architecture and
signature verified; Intel runtime requires target hardware and was not exercised.
No installation, permission changes, live input injection or third-party editor
testing was performed. Detailed earlier frequency-audit results remain below.
Local logs: `Build/release48-build.log`, `Build/release48-intel.log`.


## Second Punto report: patterned exclusions — development, 2026-10-23

Added explicit exact/prefix/substring exclusion modes to the existing settings
form. Existing exact strings retain literal semantics, including `*` and `?`.
The optional `wordExclusionRules` field decodes absent legacy data as nil; valid
rules survive persistence, export/import and recommended-mode reset. Rules are
bounded to 500 entries and 128 UTF-16 units each; partial patterns need at least
two characters. Invalid types, duplicate normalized conditions and invalid text
are rejected without committing settings.

The runtime monitor compiles rules only when settings change. Exact rules use
a set, prefix matching follows anchored trie edges, and substring matching uses
Aho–Corasick failure links. Matching never learns from typed text. Both the source
and the selected correction remain subject to exclusions; no exclusion can turn
an ambiguous alternative into an authorized replacement.

**377,475 CoreChecks passed**, including **19,725 new pattern assertions**. An
independent naive matcher is compared against the automaton over every a/b/c
string of length 0–7 with six overlapping/anchored rule sets. Additional checks
cover Unicode normalization, case, hyphens, literal metacharacters, inherited
suffix matches, empty/invalid/maximum settings, legacy JSON, two conversion
directions, punctuation, explicit replacement priority and ambiguity retention.

**713 application-configuration checks passed** with isolated disposable settings
and an invisible own window: prefix/contains form submission, duplicate rejection,
failed-save recovery, deletion, import/export and reset retention. No external UI
was read and no keyboard events were posted. Native arm64 and x86_64 cross-builds
succeeded; Intel runtime remains untested. Logs: `Build/punto2-core.log`,
`Build/punto2-settings.log`, `Build/punto2-build.log`, `Build/punto2-intel.log`.

No new dictionary decisions or unconditional switching heuristics were introduced
in this second step; the full frequency audit from the previous section was not
repeated. Application installation and GitHub release publication were not part
of this change. The [assessment](Tests/PUNTO-MECHANISMS.md) records what was adopted
and the unverified/Windows-specific claims that were not treated as specifications.

## Punto report adaptation — development changes, 2026-10-23

See [the mechanism-by-mechanism assessment](Tests/PUNTO-MECHANISMS.md).
This is an independent implementation from the packaged data, not imported
Punto code or a claim that its undocumented internals match the supplied report.

Added bounded trigram-to-bigram backoff, with independent-word support counts
and mandatory supplementary Hunspell acceptance. The existing strict path and
common-fragment recognizer are unchanged. A separate backoff evidence callback
protects newly admitted rare words from destructive punctuation splitting,
including mixed-script tokens; existing strict lexical rules retain priority.
Per-decision evidence caches expire with the decision, without input history.

**357,750 CoreChecks passed**, including **12,619 new backoff checks**. The tests
enumerate the supplementary sources to identify 21,981 Russian and 1,193 English
additional lowercase base spellings admitted by the backoff tier; these already
exist in the shipped dictionaries, and are not new externally imported entries.
An evenly distributed deterministic sample of 150 spellings per language checks
both conversion directions on all three Russian maps: correct-source retention,
whole-word results, mixed letters, four punctuation wrappers/endings, exclusions
and disabled directions. Synthetic training data additionally checks unsupported
pairs, multiple unseen triples, short/oversized tokens and independent support.

The final 80,000-entry frequency audit (one rejected upstream noise entry)
reports **zero wrong replacements and zero changes to accepted correct words**
on all three maps. Mac/PC results are identical to 0.6.47: RU 49,544 exact, 50
collisions, 405 preserved/ambiguous; EN 29,925 exact, 75 collisions. Phonetic RU
remains 47,759 exact, 2,121 collisions, 119 preserved/ambiguous. Phonetic EN has
25,659 exact and 4,341 collisions: 12 additional genuine source-word collisions
are deliberately preserved rather than overriding newly recognized Russian words.

Warm local recognition measured 800 decisions in 15 ms total on this host;
this is not a third-party editor latency measurement. Release-mode application
compilation succeeded for native arm64 and cross-compiled x86_64 using SDK 26.5.
Intel execution was not tested. Logs: `Build/punto-core-checks.log`,
`Build/punto-vocabulary.json`, `Build/punto-final-build.log`,
`Build/punto-app-intel.log` (ignored local artifacts).

No application installation, live keyboard injection, third-party editor tests,
permission changes or GitHub release publication were performed for this change.

## 0.6.47 vocabulary and startup recovery — 2026-10-23

The enumerable, locally authored extension contains **1,903 distinct spellings**:
1,306 Russian and 597 English names/brands/colloquial forms. Some were already
recognized by Hunspell; this is the size of the reviewed extension, not a claim
of 1,903 previously missing words. Russian inflections are explicit spellings.
The complete corpus is checked through all three Russian layouts paired with
both ABC and US, with lowercase/title case, nine punctuation wrappers/endings,
correct-source preservation and target exclusions. Canonical internal capitals
and apostrophe names have separate assertions; arbitrary camelCase identifiers,
addresses and intentionally mixed text remain protected.

The expanded check reproduced a real truncated-word decision before the fix:
`dfkthb.! → валери.!` instead of retaining the competing `валерию!` interpretation.
Ambiguous non-ellipsis punctuation now cannot select the shorter spelling merely
because it preserves a longer literal suffix. Matched wrappers and the existing
three-or-more-literal-period ellipsis convention retain their separate policies.
The change applies to pure and mixed-script candidates. It does not guess intent
or turn every skipped candidate into a correction.

**345,131 CoreChecks passed**, including 268,523 complete-extension assertions.
Mac and PC Russian both corrected 2,586/2,612 bare Russian case variants and all
1,194 English variants. The remaining Russian variants were left untouched.
Phonetic Russian corrected 2,390/2,612 Russian and 940/1,194 English variants;
its larger collision set is expected and is not silently treated as success.

The complete packaged frequency audit found zero incorrect replacements and
zero changes to accepted source words on all three Russian maps, both directions.
Mac/PC totals: 49,544 exact RU conversions, 50 source-word collisions, 405 skipped
or ambiguous; 29,925 exact EN conversions and 75 source-word collisions. Relative
to 0.6.46, `багаж` becomes ambiguous with the newly reviewed inflection `бага;`;
that input is preserved rather than selecting a competing spelling. Phonetic
maps also gain genuine source-word collisions from the expanded names/brands.
These are coverage limits, not a claim that every word converts automatically.

Native **arm64** release verification passed: 240 self-created keyboard-event
checks (no posting), 182 windowless NSTextView checks, 704 isolated configuration
checks, eight installer replacement/rollback tests, offline IPv4/IPv6 TCP/UDP
denial, strict signature verification, system-only library linkage and all 20
pinned resource hashes. The release retains the macOS 13.0 minimum and SDK 26.5.
Enabled-layout notifications refresh the catalog; wake recreates monitoring and
invalidates pre-sleep context. A missing layout now has its own settings state.
No input sources, permissions or login items were modified by verification.

No installation or third-party editor access occurred. Intel is cross-compiled
and package-verified; Intel runtime and other Apple Silicon/macOS combinations
remain unverified. No local Trump Switcher crash report or open GitHub issue was
available to establish the reported colleagues' specific Silicon failure.
Their build/macOS/technical counters are still needed to distinguish permission,
Secure Input, unsupported layout/field and lexical failures. Unit and bundle
checks must not be presented as resolution of every such report.

## 0.6.46 targeted reliability and latency fixes — 2026-10-22

435 new targeted checks cover delayed browser preparation, continued-typing
readback plans, overflow/selection/navigation refusal, compiled 5,000-entry
exclusions, pauses from 30 ms to two minutes, modern inflections, case-aware
names, ASCII/typographic hyphens, short English context and isolated Russian
short words. The revised imported-policy cases separately cover case, wrappers,
all-caps settings, explicit-rule precedence and target exclusions.

76,598 CoreChecks pass. The full bare-frequency audit exactly retains the previous
six outcome rows (ignoring execution time): zero incorrect replacements and zero
changes to accepted source words. This audit contains no one-/two-letter words;
the new short-word/context checks are independent of those frequency packs.
A local warm-corpus sample measured detection p50 0.024 ms, p95 0.120 ms,
maximum 0.160 ms across 320 decisions. This measures recognition only, not AX,
keyboard delivery, cold startup, user-app latency or a guarantee on other Macs.

Production observation now uses a separate serial worker, a maximum of eight
pending receipts, three bounded read-only attempts and expiry. It reads at most
the fixed 129-unit replacement span while allowing up to 128 units of later
caret advancement; it never reads that tail or writes a repair. Foreground,
field, selection and secure-input checks surround readback. Observation itself
never gates physical input; preflight and ordered-delivery safeguards remain.
Focus safety queries share a 25 ms requested budget rather than accumulating a
new timeout at every descendant. A delayed AX reply still grants no edit.

Compiled exclusions retain only user settings. Per-decision spelling caches are
discarded on return; language context retains no words and never resolves unknown
spelling or whole-word/punctuation ambiguity. No OpenCorpora import, speculative
suffix generation, fuzzy replacement, event posting, installation, permission
changes or third-party-app testing is part of this release verification.
Intel is cross-compiled and package-verified, not runtime-tested on Intel hardware.

## 0.6.45 selective upstream protections — 2026-10-22

Adapted two MIT-licensed RuSwitcher policies at revision
`436061c7fe7839ea52b1a5b4776c13611a868ddb`: source-only protection for
seven short English collision spellings and exclusions applied to the final
replacement as well as the typed token. The upstream MIT notice is included in
the app's pinned dictionary resources. Target exclusions are evaluated after
candidate selection, so they cannot silently resolve an ambiguous partial word.
Explicit rules retain priority over the new short-token guard.

The new regression failed on the preceding release for `vs`; all 122 adapted
policy cases now pass within 76,149 CoreChecks. They cover both Mac and PC Russian
physical maps, case, wrappers, exclusions in both directions, mixed scripts,
addresses, explicit rules and punctuation-key letters. In particular, `'dj` and
`'kb` retain their existing whole-word conversions, while the existing ambiguity
of `dj.` remains unchanged.

The complete vocabulary audit matches the preceding release's outcome counts on
all three Russian maps and ABC, in both directions: zero wrong replacements and
zero changes to accepted source words. Mac/PC Russian retain 49,545 exact Russian
and 29,925 exact English conversions; phonetic Russian retains 47,766 and 25,678.
Collisions and unresolved candidates remain unchanged. Upstream dictionary bytes,
input-source continuity and delivery code are unchanged. XNeur's speculative
unknown-word/proto fallback and GPL code/data were reviewed but not imported.

Release checks run without installing, changing permissions, posting key events,
or testing in third-party applications. Intel is cross-compiled, not runtime
validated on Intel hardware.

## 0.6.44 input-source continuity — 2026-10-22

Successful automatic corrections retain the corrected word's input source.
The previous unconditional 90 ms return is removed; the rollback ticket is used
only when a preflight refuses the edit before events are posted.

A new offline regression failed on the previous focus policy at the second word
after a committed replacement and geometry-only AX wrapper recreation. It passes
with the revised delivery policy in both correction directions. Separate physical
key/payload checks cover every split of the next word between old-source queued
events and newly selected-source events. Pending edits still cancel on an unproved
wrapper change; later edits still require exact field and whole-word preflight.
These checks exercise shared production policies and an editor model, without
posting events, installing on this Mac, or claiming new third-party-app validation.

## Intel release variant — 2026-10-16

Version 0.6.34 build 73 was cross-compiled for x86_64 with the macOS 26.5 SDK
and a macOS 13.0 deployment target. The bundle and DMG contain only x86_64
application code. Strict ad-hoc code-signature verification passed; the package
checker verified 19 pinned dictionary files, system-only linked libraries,
the ICNS and menu icons, and the absence of interactive diagnostic flags.
The Intel DMG passed `hdiutil verify`, exact 40-file application comparison,
Finder layout and security-shortcut checks. The ZIP passed `unzip -tq`.
The revised `setup5` image embeds a Finder alias and bookmark pointing to its
own `Trump Switcher Intel` volume. Its actual Finder window was visually checked
while the Apple Silicon DMG was mounted concurrently; the full background and
all three icons and captions were visible.

This build Mac is Apple Silicon and has no Rosetta installation. The x86_64
executable could not be launched here, so first launch, sandbox enforcement,
Accessibility behavior and corrections on Intel hardware remain unverified.

## 0.5.0 — 2026-10-09

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
