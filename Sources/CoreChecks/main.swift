import Foundation
import SwitcherCore

if CommandLine.arguments.contains("--audit-vocabulary-matrix") {
    try runVocabularyMatrixAudit()
    exit(0)
}

if CommandLine.arguments.contains("--audit-dictionary-extension") {
    try runDictionaryExtensionAudit()
    exit(0)
}

if CommandLine.arguments.contains("--audit-vocabulary") {
    try runReliabilityAudit()
    exit(0)
}

if CommandLine.arguments.contains("--audit-punctuation") {
    let dictionary = LocalDictionary()
    let en = KeyboardLayoutTable(id: "com.apple.keylayout.ABC")!
    for id in ["com.apple.keylayout.Russian", "com.apple.keylayout.RussianWin"] {
        let ru = KeyboardLayoutTable(id: id)!
        var failures = 0
        for (destination, words) in [(Layout.russian, ["привет", "для", "и", "в", "работает", "Яндекс", "такие"]),
                                      (.english, ["hello", "world", "Yandex", "thanks"])] {
            let correct = destination == .russian ? ru : en
            let wrong = destination == .russian ? en : ru
            for word in words {
                for (prefix, suffix) in [("", "."), ("", ","), ("", "!"), ("", "?"), ("", ":"), ("", ";"),
                                         ("", "..."), ("", "?!"), ("\"", "\""), ("(", ")"), ("", "—")] {
                    let expected = prefix + word + suffix
                    let input = correct.convert(expected, to: wrong)
                    let result = AutoCorrection.detect(input, recognizes: dictionary.recognizes,
                        convert: { text, target in target == .russian ? en.convert(text, to: ru) : ru.convert(text, to: en) })?.text
                    if result != expected {
                        failures += 1
                        if failures <= 18 { print("\(id): \(input) => \(result ?? "SKIP") [expected \(expected)]") }
                    }
                }
            }
        }
        print("\(id): \(failures) failures / 121 physical punctuation fixtures")
    }
    exit(0)
}

var count = 0
count += wordReplacementChecks()
count += inputDeliveryQueueChecks()
count += orderedInputCancellationChecks()
count += physicalKeyReleaseChecks()
count += boundaryDecisionHistoryChecks()
count += applicationActivationChecks()
count += sessionReplayBoundaryChecks()
count += remainingInputChecks()
count += manualConversionGateChecks()
count += inputSourceRollbackChecks()
count += layoutCoverageChecks()
count += editorCapitalizationChecks()
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    guard condition() else { fatalError("FAILED: \(name)") }
    count += 1
}
check(Conversion.convert("ghbdtn", to: .russian) == "привет", "EN to RU")
check(Conversion.convert("руддщ", to: .english) == "hello", "RU to EN")
check(Conversion.convert("Ghbdtn", to: .russian) == "Привет", "case")
check(Conversion.convert("🙂 123", to: .russian) == "🙂 123", "non-layout characters")
check(Conversion.direction("hello привет") == nil, "mixed script rejected")
check(Conversion.direction("123") == nil, "numeric input rejected")
check(Conversion.direction("ghbdtn") == .russian, "direction")
for sample in ["привет", "Ёжик", "Hello", "qwerty[];',./", "QWERTY{}:\"<>?", "@#$^&|"] {
    let target: Layout = Conversion.direction(sample) ?? .russian
    let reverse: Layout = target == .russian ? .english : .russian
    check(Conversion.convert(Conversion.convert(sample, to: target), to: reverse) == sample, "round trip")
}
check(Conversion.lastToken(in: "🙂 ghbdtn  ") == NSRange(location: 3, length: 6), "UTF16 offsets")
check(Conversion.lastToken(in: "   ") == nil, "empty token")
check(Conversion.lastToken(in: String(repeating: "a", count: 128)) == nil, "bounded read cannot truncate word")
check(Conversion.deniedApp("com.1password.1password"), "password manager blocked")
check(Conversion.deniedApp("com.apple.Terminal"), "terminal blocked")
check(!Conversion.deniedApp("com.apple.TextEdit"), "text editor allowed")
check(Conversion.allowedField(role: "AXTextArea", subrole: nil, enabled: true), "native text view without subrole")
check(!Conversion.allowedField(role: "AXTextField", subrole: "AXSecureTextField", enabled: true), "secure field rejected")
check(!Conversion.allowedField(role: "AXTextArea", subrole: "AXSecureTextField", enabled: true), "secure subtype always rejected")
check(Conversion.allowedField(role: "AXTextField", subrole: nil, enabled: true), "native single-line field without optional subrole")
check(!Conversion.allowedField(role: "AXTextField", subrole: nil, enabled: nil), "single-line field still requires enabled state")
check(!Conversion.allowedField(role: "AXTextField", subrole: "AXSearchField", enabled: true), "unhandled text-field subtype remains rejected")
check(!Conversion.allowedField(role: nil, subrole: nil, enabled: true), "unknown role rejected")
check(!Conversion.allowedField(role: "AXTextArea", subrole: nil, enabled: false), "disabled control rejected")
check(Conversion.allowedField(role: "AXTextArea", subrole: nil, enabled: nil), "TextEdit without AXEnabled allowed pending write checks")
check(!Conversion.allowedField(role: "AXTextField", subrole: "AXUnknown", enabled: nil), "ambiguous single-line enabled state rejected")
func webGroup(_ role: String? = "AXGroup", _ subrole: String? = nil, _ enabled: Bool? = true,
              _ root: Bool = true, _ bounded: Bool = true, _ selection: Bool = true) -> Bool {
    Conversion.allowedEditableGroup(role: role, subrole: subrole, enabled: enabled,
        editableRoot: root, boundedRead: bounded, selectionWritable: selection)
}
check(webGroup(), "editable Chromium group with bounded access admitted")
check(webGroup("AXGroup", "AXUnknown"), "editable group unknown subrole admitted with capabilities")
check(!webGroup("AXWebArea"), "page root cannot become an editable group")
check(!webGroup("AXGroup", "AXSecureTextField"), "secure editable group refused")
check(!webGroup("AXGroup", "AXLandmarkMain"), "landmark group refused")
check(!webGroup("AXGroup", nil, false), "disabled editable group refused")
check(!webGroup("AXGroup", nil, nil), "unknown enabled group refused")
check(!webGroup("AXGroup", nil, true, false), "ordinary group or editable descendant refused")
check(!webGroup("AXGroup", nil, true, true, false), "unbounded group refused")
check(!webGroup("AXGroup", nil, true, true, true, false), "nonwritable selection group refused")
func markers(cursor: Int, target: NSRange, lowerBound: Int = 0, limit: Int = 128) -> (Int, Int)? {
    MarkerSelection.range(caret: cursor, cursor: cursor, target: target,
        previous: { $0 > 0 ? $0 - 1 : nil }, allowed: { $0 >= lowerBound }, same: ==, limit: limit)
}
check(markers(cursor: 12, target: NSRange(location: 10, length: 1)).map { $0 == 10 && $1 == 11 } == true, "single b before one space uses field-local markers")
check(markers(cursor: 15, target: NSRange(location: 10, length: 1)).map { $0 == 10 && $1 == 11 } == true, "repeated trailing spaces stay outside replacement")
check(markers(cursor: 11, target: NSRange(location: 10, length: 1)).map { $0 == 10 && $1 == 11 } == true, "zero trailing distance endpoint")
check(markers(cursor: 10020, target: NSRange(location: 10010, length: 6)).map { $0 == 10010 && $1 == 10016 } == true, "markers do not use page-global offsets or scan field prefix")
check(markers(cursor: 20, target: NSRange(location: 10, length: 6), lowerBound: 11) == nil, "marker traversal cannot leave editable field")
check(markers(cursor: 20, target: NSRange(location: 10, length: 6), limit: 9) == nil, "oversized marker walk refused")
check(markers(cursor: 20, target: NSRange(location: -1, length: 6)) == nil, "negative marker offset refused")
check(markers(cursor: 20, target: NSRange(location: 10, length: 0)) == nil, "empty marker replacement refused")
check(markers(cursor: 20, target: NSRange(location: 21, length: 1)) == nil, "range after cursor refused")
check(markers(cursor: 20, target: NSRange(location: 19, length: 2)) == nil, "range crossing cursor refused")
check(MarkerSelection.range(caret: 5, cursor: 5, target: NSRange(location: 3, length: 1), previous: { $0 }, allowed: { _ in true }, same: ==) == nil, "stalled marker traversal refused")
let ruWords: Set<String> = ["привет", "спасибо", "дума", "думаю"]
let enWords: Set<String> = ["hello", "test", "world"]
func known(_ word: String, _ layout: Layout) -> Bool {
    (layout == .russian ? ruWords : enWords).contains(word)
}
check(AutoCorrection.detect("ghbdtn", recognizes: known)?.text == "привет", "auto RU")
check(AutoCorrection.detect("руддщ", recognizes: known)?.text == "hello", "auto EN")
check(AutoCorrection.detect("ghbdtn,", recognizes: known)?.text == "привет,", "auto punctuation")
check(AutoCorrection.detect("привет", recognizes: known) == nil, "correct word kept")
check(AutoCorrection.detect("hello", recognizes: known) == nil, "correct English kept")
check(AutoCorrection.detect("levf.", recognizes: known) == nil, "ambiguous punctuation kept")
for input in ["ab", "ghbdtn123", "ghbDtn", "GHBDTN", "ghbdtn_test", "https://test", "user@test", "hello привет"] {
    check(AutoCorrection.detect(input, recognizes: known) == nil, "unsafe auto input kept")
}
let shortPairs = [("f", "а"), ("yt", "не"), ("b", "и"), ("z", "я"), ("yf", "на"), ("ns", "ты"), ("jy", "он")]
let shortRU = Set(shortPairs.map { $0.1 })
func knownShortFixture(_ word: String, _ layout: Layout) -> Bool {
    // Reproduce NSSpellChecker accepting alphabet letters as correctly spelled.
    word.count == 1 || (layout == .russian && shortRU.contains(word))
}
for (input, expected) in shortPairs {
    check(AutoCorrection.detect(input, recognizes: knownShortFixture)?.text == expected, "common short Russian word: " + input)
}
check(AutoCorrection.detect("yt,", recognizes: knownShortFixture)?.text == "не,", "short word with punctuation")
for input in ["a", "I", "F", "Q", "x", "ab", "а", "я", "и", "не", "на", "to", "on", "in"] {
    check(AutoCorrection.detect(input, recognizes: knownShortFixture) == nil, "preserve real words and unsupported initials: " + input)
}
for separator in [" ", "\u{00a0}", "\u{202f}", "\u{2009}"] {
    check(AutoCorrection.isWordSeparator(separator), "Unicode space accepted")
    check(Conversion.lastToken(in: "nfrbt" + separator + separator) == NSRange(location: 0, length: 5), "repeated separators preserve word range")
}
for separator in ["", "  ", "\t", "\n", "\r", "x"] {
    check(!AutoCorrection.isWordSeparator(separator), "non-space trigger rejected")
}
// Browser wrappers must resolve a focused editable child, never the page itself.
func resolveFixture(_ edges: [Int: [Int]], editable: Set<Int>, focused: Set<Int>,
                    focusLinks: [Int: Int] = [:], limit: Int = 256) -> Int? {
    FocusedFieldResolver.resolve(0, same: ==, editable: { editable.contains($0) },
        focused: { focused.contains($0) }, focusChild: { focusLinks[$0] },
        children: { edges[$0] ?? [] }, limit: limit)
}
check(resolveFixture([0: [1], 1: [2]], editable: [2], focused: [2]) == 2, "web area resolves nested focused text field")
check(resolveFixture([0: [1, 2]], editable: [1, 2], focused: [2]) == 2, "unfocused sibling ignored")
check(resolveFixture([0: [1]], editable: [1], focused: []) == nil, "page does not authorize unfocused text field")
check(resolveFixture([0: [1, 2]], editable: [1, 2], focused: [1, 2]) == nil, "ambiguous focus refused")
check(resolveFixture([0: [1], 1: [0, 2]], editable: [2], focused: [2]) == 2, "cyclic accessibility tree bounded")
check(resolveFixture([0: [1], 1: [2]], editable: [2], focused: [2], limit: 2) == nil, "oversized tree refused")
check(resolveFixture([:], editable: [2], focused: [], focusLinks: [0: 1, 1: 2]) == 2, "explicit focused element chain")
check(resolveFixture([0: [1]], editable: [], focused: [1]) == nil, "secure or unsupported focused field refused")
check(AutoCorrection.detect("hf,jnftn", recognizes: { word, layout in layout == .russian && word == "работает" })?.text == "работает", "comma inside wrong-layout word")
let resourceArgument = CommandLine.arguments.firstIndex(of: "--dictionary-directory")
let resourceOverride = resourceArgument.flatMap { i in
    i + 1 < CommandLine.arguments.count ? URL(fileURLWithPath: CommandLine.arguments[i + 1]) : nil
}
// These checks deliberately exclude NSSpellChecker: packaged data must suffice.
let bundled = LocalDictionary(includeSystem: false, directory: resourceOverride)
count += importedPolicyChecks(dictionary: bundled)
count += release46Checks(dictionary: bundled)
count += reviewedVocabularyChecks(dictionary: bundled)
count += compoundDictionaryChecks(dictionary: bundled)
count += lexicalPunctuationChecks(dictionary: bundled)
count += reliabilityChecks(dictionary: bundled)
count += focusPipelineChecks(dictionary: bundled)
count += wordBoundaryChecks(dictionary: bundled)
count += complexDirectionChecks(dictionary: bundled)
check(bundled.bundledAvailable, "both packaged Hunspell dictionaries loaded")
check(bundled.frequencyCounts.russian == 50000 && bundled.frequencyCounts.english == 30000, "complete frequency packs loaded")
count += supplementalVocabularyChecks(dictionary: bundled)
for (input, expected) in shortPairs + [("nfrbt", "такие"), ("Nfrbt", "Такие"), ("hf,jnftn", "работает"), ("ghbdtn", "привет"), ("руддщ", "hello"), ("yt!", "не!")] {
    check(AutoCorrection.detect(input, recognizes: bundled.recognizes, recognizesFragment: bundled.recognizesCommon)?.text == expected, "bundled user example: " + input)
}
for word in ["клавиатурами", "срабатывают", "переключение", "словарями", "приложениях", "исправляет", "работают", "русской", "английской", "наверняка", "безопасный", "проверка"] {
    check(bundled.recognizes(word, .russian), "Russian word forms: " + word)
    let mistyped = Conversion.convert(word, to: .english)
    check(AutoCorrection.detect(mistyped, recognizes: bundled.recognizes, recognizesFragment: bundled.recognizesCommon)?.text == word, "Russian inflected conversion: " + word)
    check(AutoCorrection.detect(word, recognizes: bundled.recognizes, recognizesFragment: bundled.recognizesCommon) == nil, "correct Russian preserved: " + word)
}
for word in ["hello", "keyboard", "dictionaries", "switching", "working", "applications", "safely", "thanks", "please", "messages", "testing", "corrected"] {
    check(bundled.recognizes(word, .english), "English word forms: " + word)
    let mistyped = Conversion.convert(word, to: .russian)
    check(AutoCorrection.detect(mistyped, recognizes: bundled.recognizes, recognizesFragment: bundled.recognizesCommon)?.text == word, "English inflected conversion: " + word)
    check(AutoCorrection.detect(word, recognizes: bundled.recognizes, recognizesFragment: bundled.recognizesCommon) == nil, "correct English preserved: " + word)
}
for input in ["a", "I", "to", "on", "in", "не", "на", "а", "я", "и", "такие", "hello", "test", "руддщ123", "GHBDTN", "ghbDtn", "user@test", "ghbdtn_test"] {
    check(AutoCorrection.detect(input, recognizes: bundled.recognizes, recognizesFragment: bundled.recognizesCommon) == nil, "bundled preservation/rejection: " + input)
}
check(!bundled.recognizes("hello\u{0}ignored", .english), "NUL cannot truncate C string")
check(!bundled.recognizes("hello world", .english), "dictionary rejects phrases")
check(!LocalDictionary(includeSystem: false, directory: URL(fileURLWithPath: "/nonexistent-trumpswitcher-dictionaries")).available, "missing packaged data fails closed")
// Address syntax is independent of spelling and offline.
let addresses = AddressRecognizer(directory: bundled.resourceDirectory)
check(addresses.available && addresses.zoneCount > 1000, "IANA zones bundled and loaded")
check(AutoCorrection.detect("нфтвучюкг", recognizes: bundled.recognizes, recognizesFragment: bundled.recognizesCommon, isAddress: addresses.recognizes)?.text == "yandex.ru", "exact user domain example")
let addressSamples = ["yandex.ru", "google.com", "www.yandex.ru", "mail.google.com", "github.io", "example.co.uk", "my-site123.dev", "EXAMPLE.RU", "xn--e1afmkfd.xn--p1ai", "https://yandex.ru", "https://example.com/a/../b", "ftp://example.org/file", "http://localhost:8080", "127.0.0.1", "http://127.0.0.1:8080/test", "example.ru:443/path", "https://example.com/search?q=123&x=test#top", "https://example.com/a%20b", "name.surname+tag@example.org", "user123@mail.example.ru", "mailto:user@example.com"]
for expected in addressSamples {
    check(addresses.recognizes(expected), "valid offline address syntax: " + expected)
    check(AutoCorrection.detect(expected, recognizes: bundled.recognizes, recognizesFragment: bundled.recognizesCommon, isAddress: addresses.recognizes) == nil, "correct ASCII address preserved: " + expected)
    let wrong = Conversion.convert(expected, to: .russian)
    let correction = AutoCorrection.detect(wrong, recognizes: bundled.recognizes, recognizesFragment: bundled.recognizesCommon, isAddress: addresses.recognizes)
    check(correction?.text == expected && correction?.layout == .english, "wrong-layout address: " + expected)
    var typed = TypingBuffer()
    for char in wrong { typed.append(String(char)) }
    check(typed.finishWord() == wrong, "keyboard buffer retains punctuation/digits for address")
    let keys = KeyboardReplacement.keys(original: wrong, corrected: expected, layout: .english)!
    check(keys.compactMap(\.text).joined() == expected + " ", "address keyboard output includes one space")
    let enterKeys = KeyboardReplacement.keys(original: wrong, corrected: expected, layout: .english, appendSpace: false)!
    check(enterKeys.compactMap(\.text).joined() == expected, "Enter/Tab address output contains no extra space")
    check(!enterKeys.contains { [36,48,49,76].contains($0.code) }, "no synthetic submit/focus/space in Enter/Tab plan")
}
for invalid in ["hello", "user@test", "a..b@example.com", "@example.com", "a@b@c.ru", "-bad.ru", "bad-.ru", "bad..ru", "foo.invalidzone", "foo.123", "https://", "http://bad.ru:", "http://bad.ru:70000", "http://bad.ru:word", "http://999.0.0.1", "http://01.0.0.1", "example.ru?", "example.ru#", "http://example.ru/%ZZ", "hello/world", "ghbdtn_test", "hello1", "path\\file.ru", "example.ru\u{0}tail"] {
    check(!addresses.recognizes(invalid), "invalid addresses remain untouched: " + invalid)
}
for original in ["пример.рф", "мой-сайт.рус", "пример.com", "hello", "привет", "руддщ123", "ghbdtn_test", "user@test"] {
    check(AutoCorrection.detect(original, recognizes: bundled.recognizes, recognizesFragment: bundled.recognizesCommon, isAddress: addresses.recognizes) == nil, "real Cyrillic domains and non-addresses preserved: " + original)
}
let longURL = "https://example.com/" + String(repeating: "a", count: 65)
check(addresses.recognizes(longURL), "address over old 48-character word limit accepted")
let wrongLongURL = Conversion.convert(longURL, to: .russian)
check(AutoCorrection.detect(wrongLongURL, recognizes: bundled.recognizes, recognizesFragment: bundled.recognizesCommon, isAddress: addresses.recognizes)?.text == longURL, "long URL converted in full")
check(AutoCorrection.detect(String(repeating: "a", count: 49), recognizes: { _, _ in true }) == nil, "ordinary spelling limit remains 48")
check(!addresses.recognizes("https://example.com/" + String(repeating: "a", count: 128)), "overlong URL refused without truncation")
check(!AddressRecognizer(directory: URL(fileURLWithPath: "/missing-address-resources")).available, "missing zone file fails closed")
// System keyboard mode: independent of app/field write APIs and typing speed.
var typing = TypingBuffer()
for input in ["b", "f", "yt", "nfrbt", "hf,jnftn", "ghbdtn", "руддщ", "hello", "привет"] {
    for char in input { typing.append(String(char)) }
    check(typing.finishWord() == input, "typed word retained until boundary: " + input)
    check(typing.token.isEmpty, "no prior word after boundary")
    check(typing.finishWord() == nil, "repeated spaces do not reprocess previous word")
}
typing.append("g"); typing.append("x"); typing.backspace(); typing.append("h")
check(typing.finishWord() == "gh", "backspace edits current word")
typing.backspace(); typing.append("b")
check(typing.finishWord() == nil, "backspace into unknown prefix blocks partial correction")
typing.append("b"); typing.reset(startOfWord: false); typing.append("f")
check(typing.finishWord() == nil, "navigation and shortcuts invalidate current word")
typing.append("b")
check(typing.finishWord() == "b", "space resynchronizes after navigation")
for input in ["hello1", "ghbdtn_test", "user@test", "ghbdtn-test", "🙂", "pasted text", String(repeating: "f", count: 129)] {
    typing.reset()
    for char in input { typing.append(String(char)) }
    let completed = typing.finishWord()
    check(completed == nil || AutoCorrection.detect(completed!, recognizes: bundled.recognizes, recognizesFragment: bundled.recognizesCommon) == nil,
          "unsafe or non-address token does not convert: " + input.prefix(12))
}
for char in "hello/world" { typing.append(String(char)) }
check(typing.finishWord().flatMap { AutoCorrection.detect($0, recognizes: bundled.recognizes, recognizesFragment: bundled.recognizesCommon) } == nil, "paths cannot trigger keyboard replacement")
typing.append("ghbdtn")
check(typing.finishWord() == nil, "multi-character events are not counted as individual keystrokes")
for (input, expected) in shortPairs + [("hf,jnftn", "работает"), ("руддщ", "hello"), ("Ghbdtn", "Привет"), ("yt!", "не!")] {
    typing.reset()
    for char in input { typing.append(String(char)) }
    let token = typing.finishWord()!
    let correction = AutoCorrection.detect(token, recognizes: bundled.recognizes, recognizesFragment: bundled.recognizesCommon)!
    let keys = KeyboardReplacement.keys(original: token, corrected: correction.text, layout: correction.layout)!
    check(keys.prefix(input.count).allSatisfy { $0.code == 51 && $0.text == nil && !$0.shift }, "delete exact typed characters")
    check(keys.compactMap(\.text).joined() == expected + " ", "replacement and exactly one space: " + input)
    check(keys.last?.code == 49, "replacement ends with space, never submits form")
    check(keys.count == input.count + expected.count + 1, "bounded injection size")
}
let russianB = KeyboardReplacement.keys(original: "b", corrected: "и", layout: .russian)!
check(russianB[1].code == 11 && !russianB[1].shift, "Russian и uses B physical key")
let englishHello = KeyboardReplacement.keys(original: "руддщ", corrected: "hello", layout: .english)!
check(Array(englishHello.dropFirst(5).dropLast()).map(\.code) == [4,14,37,37,31], "English hello uses matching physical keys")
let capital = KeyboardReplacement.keys(original: "Ghbdtn", corrected: "Привет", layout: .russian)!
check(capital[6].code == 5 && capital[6].shift && !capital[7].shift, "initial uppercase uses Shift on correct physical key")
check(KeyboardReplacement.keys(original: "b", corrected: "🙂", layout: .russian) == nil, "unsupported replacement refused before deletion")
check(KeyboardReplacement.keys(original: "", corrected: "и", layout: .russian) == nil, "empty original refused")
for id in ["com.apple.Terminal", "com.googlecode.iterm2", "com.microsoft.VSCode", "com.apple.dt.Xcode", "com.openai.codex", "ru.keepcoder.Telegram", "com.apple.TextEdit"] {
    check(!KeyboardSafety.passwordApp(id), "ordinary apps have no auto exclusion: " + id)
}
for id in ["com.1password.1password", "com.apple.Passwords", "com.bitwarden.desktop"] {
    check(KeyboardSafety.passwordApp(id), "password manager remains excluded")
}
for role in [nil, "AXGroup", "AXWebArea", "AXTextField", "AXTextArea"] {
    check(KeyboardSafety.allowed(role: role, subrole: nil, protected: nil, enabled: nil), "keyboard engine does not require field text APIs")
    check(!KeyboardSafety.allowed(role: role, subrole: "AXSecureTextField", protected: nil, enabled: true), "secure subtype blocks capture")
    check(!KeyboardSafety.allowed(role: role, subrole: nil, protected: true, enabled: true), "protected content blocks capture")
}
check(!KeyboardSafety.allowed(role: "AXButton", subrole: nil, protected: nil, enabled: true), "button shortcuts are not text")
check(!KeyboardSafety.allowed(role: "AXTextField", subrole: nil, protected: nil, enabled: false), "disabled field blocked")
// Physical fallback and the emitted keys must agree in both layouts.
for (layout, sample) in [(Layout.russian, "абвгдеёжзийклмнопрстуфхцчшщъыьэюяАБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ.,!?:;"), (.english, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.,!?:;")] {
    for char in sample {
        let key = KeyboardReplacement.keys(original: "x", corrected: String(char), layout: layout)![1]
        check(KeyboardInput.character(code: key.code, shift: key.shift, capsLock: false, layout: layout) == String(char), "physical fallback agrees with replacement")
    }
}
check(KeyboardInput.character(code: 11, shift: false, capsLock: false, layout: .russian) == "и", "B fallback without Unicode")
check(KeyboardInput.character(code: 11, shift: true, capsLock: false, layout: .russian) == "И", "Shift B fallback")
check(KeyboardInput.character(code: 11, shift: true, capsLock: true, layout: .russian) == "и", "Shift cancels Caps Lock")
check(KeyboardInput.character(code: 126, shift: false, capsLock: false, layout: .russian) == nil, "arrow has no fallback character")
// Reproduce first-word loss after idle and Qt's unchanged window focus hints.
var session = TypingBuffer()
session.noteKey(at: 1); session.append("x")
session.reset() // A different application has a fresh word and fresh clock.
session.noteKey(at: 100)
for char in "ghbdtn" { session.append(String(char)) }
check(session.finishWord() == "ghbdtn", "first word after switching apps and long idle is retained")
session.noteKey(at: 1000)
for char in "ghbdtn" {
    session.append(String(char))
    session.updateFocus(changed: false)
}
check(session.finishWord() == "ghbdtn", "Qt window focus hints on each key do not erase typed word")
session.noteKey(at: 2000); session.append("g")
session.noteKey(at: 2031); session.append("h")
check(session.finishWord() == "gh", "pause does not discard the first half of a word")
session.noteKey(at: 2100); session.append("b")
check(session.finishWord() == "b", "first word after idle at a known boundary is accepted")
for char in "old" { session.append(String(char)) }; session.updateFocus(changed: true)
session.append("b")
check(session.finishWord() == "b", "real field change clears old text and arms new first word")
// Expanded punctuation, function words and persisted custom policy.
for (input, output) in [("lkz", "для"), ("b", "и"), ("d", "в"), ("r", "к"), ("c", "с"),
                         ("j", "о"), ("e", "у"), ("ф", "a"), ("ш", "i"), ("Ш", "I"), ("lkz.", "для."), ("b...", "и..."),
                         ("(ghbdtn)", "(привет)"), ("«ghbdtn»", "«привет»"),
                         ("ghbdtn,b", "привет,и"), ("b.d", "и.в"), ("rfr-nj", "как-то"),
                         ("bp-pf", "из-за"), ("руддщю", "hello."), ("руддщююю", "hello...")] {
    check(AutoCorrection.detect(input, recognizes: bundled.recognizes, recognizesFragment: bundled.recognizesCommon)?.text == output, "expanded correction: " + input)
}
for input in ["hello,world", "и,в", "из-за", "как-то", "hello.world", "yandex.ru.", "(yandex.ru)", "ghbdtn_test", "ghbdtn123"] {
    check(AutoCorrection.detect(input, recognizes: bundled.recognizes, recognizesFragment: bundled.recognizesCommon) == nil, "expanded preservation: " + input)
}
for wrapper in [("(", ")"), ("[", "]"), ("{", "}"), ("«", "»"), ("“", "”"), ("‘", "’"), ("\"", "\"")] {
    for (input, output) in [("lkz", "для"), ("b", "и"), ("d", "в"), ("ghbdtn", "привет"), ("руддщ", "hello")] {
        for suffix in ["", ".", ",", "!", "?", "…", "...", "?!"] {
            let token = wrapper.0 + input + wrapper.1 + suffix
            check(AutoCorrection.detect(token, recognizes: bundled.recognizes, recognizesFragment: bundled.recognizesCommon)?.text == wrapper.0 + output + wrapper.1 + suffix, "wrapped short/long punctuation: " + token)
        }
    }
}
check(AutoCorrection.detect("вщтэе", recognizes: bundled.recognizes, recognizesFragment: bundled.recognizesCommon)?.text == "don't", "English apostrophe contraction")

let macTable = KeyboardLayoutTable(id: "com.apple.keylayout.Russian")!
check(macTable.character(code: 49, shift: false, capsLock: false) == " ", "normal physical Space")
check(macTable.character(code: 49, shift: false, capsLock: false, option: true) == "\u{00a0}", "Option Space is NBSP")
check(macTable.replacement("\u{00a0}")?.code == 49 && macTable.replacement("\u{00a0}")?.option == true, "NBSP output keeps Option Space")
var policy = CorrectionSettings()
policy.excludedWords = ["ghbdtn"]
policy.rules = [CorrectionRule(input: "ghbdtn", output: "тест", russian: true), CorrectionRule(input: "hello", output: "привет", russian: true)]
check(AutoCorrection.detect("ghbdtn", recognizes: bundled.recognizes, recognizesFragment: bundled.recognizesCommon, settings: policy) == nil, "exclusion wins over rule")
check(AutoCorrection.detect("(ghbdtn),", recognizes: bundled.recognizes, recognizesFragment: bundled.recognizesCommon, settings: policy) == nil, "excluded stem with wrapper")
check(AutoCorrection.detect("hello", recognizes: bundled.recognizes, recognizesFragment: bundled.recognizesCommon, settings: policy)?.text == "привет", "explicit rule overrides known source word")
check(AutoCorrection.detect("(hello)!", recognizes: bundled.recognizes, recognizesFragment: bundled.recognizesCommon, settings: policy)?.text == "(привет)!", "rule inside wrappers")
check(AutoCorrection.detect("(hello)!", recognizes: bundled.recognizes, recognizesFragment: bundled.recognizesCommon, settings: policy)?.preservesExactCase == true, "explicit rule retains exact output capitalization inside wrappers")
check(AutoCorrection.detect("ghbdtn", recognizes: bundled.recognizes, recognizesFragment: bundled.recognizesCommon)?.preservesExactCase == false, "dictionary correction can preserve editor capitalization")
policy.toRussian = false
check(AutoCorrection.detect("hello", recognizes: bundled.recognizes, recognizesFragment: bundled.recognizesCommon, settings: policy) == nil, "disabled direction includes rules")
policy = CorrectionSettings(); policy.shortWords = false
check(AutoCorrection.detect("b", recognizes: bundled.recognizes, recognizesFragment: bundled.recognizesCommon, settings: policy) == nil, "short word policy")
policy = CorrectionSettings(); policy.punctuation = false
check(AutoCorrection.detect("(ghbdtn)", recognizes: bundled.recognizes, recognizesFragment: bundled.recognizesCommon, settings: policy) == nil, "punctuation policy")
policy = CorrectionSettings(); policy.addresses = false
check(AutoCorrection.detect("нфтвучюкг", recognizes: bundled.recognizes, recognizesFragment: bundled.recognizesCommon, settings: policy) == nil, "address policy")
policy = CorrectionSettings(); policy.allowAllCaps = true
check(AutoCorrection.detect("GHBDTN", recognizes: bundled.recognizes, recognizesFragment: bundled.recognizesCommon, settings: policy)?.text == "ПРИВЕТ", "optional capitals policy")
policy.rules = [CorrectionRule(input: "tt", output: "тест текста", russian: true)]
check(CorrectionSettings.decode(try! JSONEncoder().encode(policy)) == policy, "settings round trip")
policy.rules.append(CorrectionRule(input: "bad", output: "text\n", russian: false))
check(CorrectionSettings.decode(try! JSONEncoder().encode(policy)) == nil, "rule cannot synthesize Enter")
check(CorrectionSettings.decode(Data("{}".utf8)) == nil, "incomplete settings rejected")
// Read real Apple tables without changing the user's active source. This catches
// the Russian-Mac / Russian-PC punctuation mismatch of the old implementation.
let englishTable = KeyboardLayoutTable(id: "com.apple.keylayout.ABC")!
for id in InputSources.russianIDs {
    let table = KeyboardLayoutTable(id: id)!
    check(table.character(code: 11, shift: false, capsLock: false) != nil, "Apple Russian table loaded: " + id)
    for (_, character) in table.characters {
        guard let replacement = table.replacement(character) else { fatalError("Unrepresentable Apple output") }
        check(table.character(code: replacement.code, shift: replacement.shift, capsLock: replacement.capsLock, option: replacement.option) == character, "Apple physical replacement agrees: " + id)
        // Exact modifier values are read from UCKeyTranslate. Some non-letter
        // physical keys output letters only with Shift/Caps; don't case-fold
        // their glyphs to invent a second, conflicting keyboard table.
    }
    let baseB = table.character(code: 11, shift: false, capsLock: false)!
    check(table.character(code: 11, shift: true, capsLock: true) == baseB.uppercased(), "macOS Caps Lock stays uppercase with Shift")
    for expected in ["для", "и", "в", "не", "такие", "работает", "привет", "Привет", "и.", "для,", "(привет)!", "yandex.ru", "https://yandex.ru/path?q=1", "user@mail.ru"] {
        let direction: Layout = Conversion.direction(expected) == .russian ? .english : .russian
        let from = direction == .english ? englishTable : table
        let to = direction == .english ? table : englishTable
        let wrong = from.convert(expected, to: to)
        let target = direction == .english ? Layout.english : .russian
        let correction = AutoCorrection.detect(wrong, recognizes: bundled.recognizes, recognizesFragment: bundled.recognizesCommon, convert: { text, layout in
            layout == .russian ? englishTable.convert(text, to: table) : table.convert(text, to: englishTable)
        })
        // Genuine Latin words in a phonetic layout can be ambiguous. They are
        // preserved rather than forced; ordinary standard/PC examples must pass.
        if id != "com.apple.keylayout.Russian-Phonetic" {
            check(correction?.text == expected || (expected == "для," && correction?.text == "для?"), "real Apple wrong layout: " + id + " " + expected + " input=" + wrong)
        }
        if let correction {
            let outputTable = target == .russian ? table : englishTable
            let keys = KeyboardReplacement.keys(original: wrong, corrected: correction.text, layout: target, appendSpace: false,
                keyProvider: { char, _ in outputTable.replacement(char) })
            check(keys != nil, "actual physical correction plan ready")
        }
    }
}
check(KeyboardLayoutTable(id: "com.apple.keylayout.Russian")!.character(code: 42, shift: false, capsLock: false) == "ё", "Mac ё is on backslash key")
check(KeyboardLayoutTable(id: "com.apple.keylayout.Russian")!.character(code: 26, shift: true, capsLock: false) == ".", "Mac dot is Shift 7")
check(KeyboardLayoutTable(id: "com.apple.keylayout.RussianWin")!.character(code: 44, shift: false, capsLock: false) == ".", "PC dot is slash key")
let russianWinTable = KeyboardLayoutTable(id: "com.apple.keylayout.RussianWin")!
check(russianWinTable.character(code: 10, shift: false, capsLock: false) == "ё", "PC Russian also exposes ё on ISO section key")
check(russianWinTable.character(code: 50, shift: false, capsLock: false) == "ё", "PC Russian exposes ё on ANSI grave key")
check(russianWinTable.key(for: "ё")?.code == 50, "ambiguous glyph prefers ANSI physical position")
check(russianWinTable.convert("ёлка", to: englishTable) == "`krf", "PC Russian ё converts through ANSI grave key")
check(russianWinTable.replacement("ё")?.code == 50, "PC Russian replacement uses ANSI grave key")

// Regressions for user-reported proper names and stale key payloads during fast typing.
let abcTable = KeyboardLayoutTable(id: "com.apple.keylayout.ABC")!
let queuedRU = QueuedLayoutTransition(previous: abcTable, target: macTable, boundary: 1000, selectedAt: 2000)
let queuedEN = QueuedLayoutTransition(previous: macTable, target: abcTable, boundary: 1000, selectedAt: 2000)
for (target, samples) in [(Layout.russian, ["яндекс", "Яндекс", "Яндекса", "Яндексе", "Телеграм", "Гугл", "Ватсап", "Москва", "Игорь"]),
                          (.english, ["Yandex", "Telegram", "WhatsApp", "Google", "Codex", "ChatGPT", "Firefox"])] {
    for expected in samples {
        let from = target == .russian ? macTable : abcTable
        let to = target == .russian ? abcTable : macTable
        let input = from.convert(expected, to: to)
        // Mixed capitals are intentional product names: explicit CAPS policy only
        // permits all-caps, so camel-case product spellings stay conservative.
        do {
            let detected = AutoCorrection.detect(input, recognizes: bundled.recognizes, recognizesFragment: bundled.recognizesCommon, convert: { text, _ in to.convert(text, to: from) })
            check(detected?.text == expected, "common proper name correction: " + expected)
        }
        check(bundled.recognizes(expected, target), "proper name and inflection included locally: " + expected)
        check(AutoCorrection.detect(expected, recognizes: bundled.recognizes, recognizesFragment: bundled.recognizesCommon) == nil, "correct proper name preserved: " + expected)
    }
}
for (input, expected) in [("Янlеrc", "Яндекс"), ("приdtт", "привет"), ("руllo", "hello"), ("(приdtт)", "(привет)")] {
    let detected = AutoCorrection.detect(input, recognizes: bundled.recognizes, recognizesFragment: bundled.recognizesCommon,
        convert: { text, target in target == .russian ? abcTable.convert(text, to: macTable) : macTable.convert(text, to: abcTable) })
    check(detected?.text == expected, "complete mixed-script word recovered: " + input)
}
for input in ["helloпривет", "abcИгорь", "foo_приdtт", "приdtт123", "янdex.ru", "idСodex"] {
    check(AutoCorrection.detect(input, recognizes: bundled.recognizes, recognizesFragment: bundled.recognizesCommon,
        convert: { text, target in target == .russian ? abcTable.convert(text, to: macTable) : macTable.convert(text, to: abcTable) }) == nil,
          "mixed identifiers/addresses/unknown words preserved: " + input)
}
var noMixedPunctuation = CorrectionSettings(); noMixedPunctuation.punctuation = false
check(AutoCorrection.detect("(приdtт)", recognizes: bundled.recognizes, recognizesFragment: bundled.recognizesCommon, settings: noMixedPunctuation,
    convert: { text, target in target == .russian ? abcTable.convert(text, to: macTable) : macTable.convert(text, to: abcTable) }) == nil,
    "mixed wrapped word respects punctuation setting")
var mixedPolicy = CorrectionSettings(); mixedPolicy.excludedWords = ["приdtт"]
check(AutoCorrection.detect("приdtт", recognizes: bundled.recognizes, recognizesFragment: bundled.recognizesCommon, settings: mixedPolicy) == nil, "mixed word respects exclusion")
for (transition, typed, expected) in [(queuedRU, "ghbdtn", "привет"), (queuedEN, "руддщ", "hello")] {
    var stream = TypingBuffer(); var result = ""
    for (index, char) in typed.enumerated() {
        let key = transition.previous.key(for: String(char))!
        let normalized = transition.normalized(String(char), code: key.code, shift: key.shift, capsLock: false, option: false,
                                              timestamp: UInt64(3000 + index), currentID: transition.target.id, systemEvent: true)
        result += normalized ?? String(char); stream.append(normalized ?? String(char))
    }
    check(result == expected && stream.finishWord() == expected, "queued next word has a single alphabet after switch")
}
for timestamp: UInt64 in [0, 1000, queuedRU.deadline + 1, UInt64.max] {
    check(queuedRU.normalized("g", code: 5, shift: false, capsLock: false, option: false,
                             timestamp: timestamp, currentID: macTable.id, systemEvent: true) == nil, "old/expired events never rewritten")
}
check(queuedRU.normalized("g", code: 5, shift: false, capsLock: false, option: false, timestamp: 3000, currentID: abcTable.id, systemEvent: true) == nil, "manual source change cancels reconciliation")
check(queuedRU.normalized("g", code: 5, shift: false, capsLock: false, option: false, timestamp: 3000, currentID: macTable.id, systemEvent: false) == nil, "other software's injected Unicode left alone")
check(queuedRU.normalized("q", code: 5, shift: false, capsLock: false, option: false, timestamp: 3000, currentID: macTable.id, systemEvent: true) == nil, "payload must match its physical position")
check(queuedRU.normalized("G", code: 5, shift: true, capsLock: false, option: false, timestamp: 3000, currentID: macTable.id, systemEvent: true) == "П", "Shift reconciled")
check(queuedRU.normalized("G", code: 5, shift: false, capsLock: true, option: false, timestamp: 3000, currentID: macTable.id, systemEvent: true) == "П", "Caps Lock reconciled")
check(queuedRU.normalized("G", code: 5, shift: true, capsLock: true, option: false, timestamp: 3000, currentID: macTable.id, systemEvent: true) == "П", "macOS Shift with Caps Lock reconciled")
for code: UInt16 in [51, 53, 123, 124, 125, 126] {
    check(queuedRU.normalized("g", code: code, shift: false, capsLock: false, option: false, timestamp: 3000, currentID: macTable.id, systemEvent: true) == nil, "nonprinting keys never rewritten")
}
for role in [nil, "AXWindow", "AXGroup", "AXWebArea"] {
    check(!FocusTracking.shouldReset(previousRole: role, nextRole: role, identityChanged: true, alreadyReset: false), "unstable wrapper focus does not erase a word")
}
check(FocusTracking.shouldReset(previousRole: "AXTextField", nextRole: "AXTextField", identityChanged: true, alreadyReset: false), "different text field invalidates token")
check(!FocusTracking.shouldReset(previousRole: "AXTextField", nextRole: "AXTextField", identityChanged: false, alreadyReset: false), "unchanged text field retains token")
check(!FocusTracking.shouldReset(previousRole: "AXTextArea", nextRole: "AXTextField", identityChanged: true, alreadyReset: true), "click reset is not repeated halfway through new word")

// Regression matrix: punctuation encoded by the actual Russian-Mac keyboard,
// including quotes (@), colon (Ж), ё (backslash), and sentence-ending dashes.
let macConvert: (String, Layout) -> String = { text, target in
    target == .russian ? abcTable.convert(text, to: macTable) : macTable.convert(text, to: abcTable)
}
for (target, words) in [(Layout.russian, ["привет", "для", "и", "в", "работает", "Яндекс", "такие", "её", "ещё", "это", "этот", "эти", "хоть"]),
                         (.english, ["hello", "world", "Yandex", "thanks"])] {
    let correct = target == .russian ? macTable : abcTable
    let wrong = target == .russian ? abcTable : macTable
    for word in words {
        for (prefix, suffix) in [("", "."), ("", ","), ("", "!"), ("", "?"), ("", ":"), ("", ";"),
                                 ("", "..."), ("", "?!"), ("\"", "\""), ("(", ")"), ("", "—"), ("", "–")] {
            let expected = prefix + word + suffix
            let input = correct.convert(expected, to: wrong)
            let result = AutoCorrection.detect(input, recognizes: bundled.recognizes, recognizesFragment: bundled.recognizesCommon, convert: macConvert)
            check(result?.text == expected, "Mac physical punctuation regression: " + input + " → " + expected)
            check(AutoCorrection.detect(expected, recognizes: bundled.recognizes, recognizesFragment: bundled.recognizesCommon, convert: macConvert) == nil,
                  "correct punctuation preserved: " + expected)
        }
    }
}
for word in "срабатывает через раз вообще работает непонятно как это функционирует почему таких проблем нет Яндекс заимствуй также нужно учитывать знаки препинания которые могут быть конце слов исправь навсегда".split(separator: " ").map(String.init) {
    let input = macTable.convert(word, to: abcTable)
    check(AutoCorrection.detect(input, recognizes: bundled.recognizes, recognizesFragment: bundled.recognizesCommon, convert: macConvert)?.text == word,
          "ordinary vocabulary from reported scenario: " + word)
}
for input in ["user@example.com", "foo_bar", "hello/world", "ghbdtn_test", "API", "hello", "(hello)!", "print(hello)"] {
    check(AutoCorrection.detect(input, recognizes: bundled.recognizes, recognizesFragment: bundled.recognizesCommon, convert: macConvert) == nil,
          "symbols do not authorize code/identifier changes: " + input)
}
check(TypingShortcut.action(code: 49, command: false, control: true, option: false, shift: false) == .inputSource,
      "Control Space does not consume a word separator")
check(TypingShortcut.action(code: 49, command: false, control: true, option: false, shift: true) == .inputSource,
      "Control Shift Space preserves tracked text")
check(TypingShortcut.action(code: 49, command: false, control: true, option: true, shift: false) == .invalidate,
      "manual conversion hotkey invalidates automatic tracking")
check(TypingShortcut.action(code: 0, command: true, control: false, option: false, shift: false) == .selectAll,
      "Cmd A arms replacement of the selected prefix")
check(TypingShortcut.action(code: 8, command: true, control: false, option: false, shift: false) == .invalidate,
      "unrelated shortcuts remain conservative")
var shortcutBuffer = TypingBuffer()
TypingShortcut.inputSource.apply(to: &shortcutBuffer)
for character in "ghbdtn" { shortcutBuffer.append(String(character)) }
check(shortcutBuffer.finishWord() == "ghbdtn", "first word after layout shortcut survives")
for deleteFirst in [false, true] {
    shortcutBuffer.reset(startOfWord: false)
    TypingShortcut.selectAll.apply(to: &shortcutBuffer)
    if deleteFirst { shortcutBuffer.backspace() }
    for character in "руддщ" { shortcutBuffer.append(String(character)) }
    check(shortcutBuffer.finishWord() == "руддщ", "Cmd A then typing/deletion retains complete replacement")
}
for character in "при" { shortcutBuffer.append(String(character)) }
TypingShortcut.inputSource.apply(to: &shortcutBuffer)
for character in "dtn" { shortcutBuffer.append(String(character)) }
check(shortcutBuffer.finishWord().flatMap { AutoCorrection.detect($0, recognizes: bundled.recognizes, recognizesFragment: bundled.recognizesCommon, convert: macConvert) }?.text == "привет",
      "manual layout switch inside word retains enough text to recover mixed alphabet")
for (symbol, mapped, immediate) in [("!", "!", true), ("&", ".", true), ("^", ":", true), ("…", "…", true),
                                    (",", "б", false), (".", "ю", false), (";", "ж", false), ("'", "э", false)] {
    check(WordBoundary.isImmediate(symbol, mapped: mapped, token: "ghbdtn", mappedToken: "привет") == immediate,
          "literal/mapped punctuation boundary: " + symbol)
}
for (word, mapped, symbol) in [("https://example.org/search", "", "?"), ("user@example.org", "", "!"),
                               ("нфтвучюкг", "yandex.ru", "!"), ("hello.world", "", ";"), ("foo_bar", "", "!")] {
    check(!WordBoundary.isImmediate(symbol, mapped: symbol, token: word, mappedToken: mapped),
          "boundary cannot split an address or identifier")
}
// Replay real physical keys and apply the generated backspace/typing plans to a
// scratch editor. In particular, the punctuation key has NOT reached that editor
// when replacement begins, so it must never add an extra deletion or space.
for (target, phrases) in [(Layout.russian, ["привет! для, и в. Яндекс…", "работает!такие слова.", "для: привет; её!", "\"привет\" ", "её, ещё! "]),
                          (.english, ["hello! world, Yandex…", "hello: thanks; ", "\"hello\"! "])] {
    let intended = target == .russian ? macTable : abcTable
    var active = target == .russian ? abcTable : macTable
    for phrase in phrases {
        active = target == .russian ? abcTable : macTable
        var stream = TypingBuffer(); var editor = ""
        for character in phrase {
            let key = intended.replacement(String(character))!
            let typed = active.character(code: key.code, shift: key.shift, capsLock: false, option: key.option)!
            let other = active.id == abcTable.id ? macTable : abcTable
            let punctuation = WordBoundary.isImmediate(typed, mapped: active.convert(typed, to: other), token: stream.token,
                                                        mappedToken: active.convert(stream.token, to: other))
            if typed == " " || punctuation {
                if let original = stream.finishWord(),
                   let correction = AutoCorrection.detect(original + (punctuation ? typed : ""), recognizes: bundled.recognizes, recognizesFragment: bundled.recognizesCommon, convert: macConvert) {
                    active = correction.layout == .russian ? macTable : abcTable
                    let plan = KeyboardReplacement.keys(original: original, corrected: correction.text, layout: correction.layout,
                                                        appendSpace: typed == " ", keyProvider: { text, _ in active.replacement(text) })!
                    for output in plan {
                        if output.code == 51 { check(!editor.isEmpty, "stream replacement cannot delete past typed prefix"); editor.removeLast() }
                        else { editor += output.text! }
                    }
                } else { editor += typed }
            } else { stream.append(typed); editor += typed }
        }
        check(editor == phrase, "physical multiword stream with punctuation: " + phrase + " actual=" + editor)
    }
}

let benchmarkStart = Date()
for _ in 0..<100 {
    for input in ["b", "нфтвучюкг", "руддщ", "hf,jnftn", "hello", "такие", "dictionary", "abcdefghijklmnp"] {
        _ = AutoCorrection.detect(input, recognizes: bundled.recognizes, recognizesFragment: bundled.recognizesCommon)
    }
}
let elapsedMS = Date().timeIntervalSince(benchmarkStart) * 1000
print("800 bundled keyboard decisions: \(Int(elapsedMS)) ms total")
if CommandLine.arguments.contains("--system-dictionaries") {
    let dictionary = SystemDictionary()
    check(dictionary.available, "system RU/EN dictionaries available")
    for (input, expected) in shortPairs + [("nfrbt", "такие"), ("Nfrbt", "Такие"), ("yt!", "не!")] {
        check(AutoCorrection.detect(input, recognizes: dictionary.recognizes)?.text == expected, "real dictionary user example: " + input)
    }
    for input in ["a", "I", "to", "on", "in", "не", "на", "а", "я", "и", "такие"] {
        check(AutoCorrection.detect(input, recognizes: dictionary.recognizes) == nil, "real dictionary correct short word: " + input)
    }
    check(AutoCorrection.detect("hf,jnftn", recognizes: dictionary.recognizes)?.text == "работает", "screenshot word recognized by system dictionary")
    check(AutoCorrection.detect("ghbdtn", recognizes: dictionary.recognizes)?.text == "привет", "real dictionary RU")
    check(AutoCorrection.detect("руддщ", recognizes: dictionary.recognizes)?.text == "hello", "real dictionary EN")
    check(AutoCorrection.detect("hello", recognizes: dictionary.recognizes) == nil, "real dictionary preserves English")
}
if CommandLine.arguments.contains("--system-layouts") {
    check(InputSources.enabled(matching: "local.trumpswitcher.nonexistent-layout").isEmpty, "missing input source returns empty without crashing")
    check(InputSources.available(.english), "enabled English source including ABC fallback")
    check(InputSources.available(.russian), "enabled Russian source")
}
for state: Int64 in [-1, 0, 1, 2, 1_909_850_543, Int64.max] {
    check(KeyboardEventOrigin.isSystem(stateID: state, userData: 0) == (state == 0 || state == 1), "Quartz source-state identity")
    check(!KeyboardEventOrigin.isSystem(stateID: state, userData: 123), "Tagged input never becomes physical input")
}
print("Passed \(count) checks")
