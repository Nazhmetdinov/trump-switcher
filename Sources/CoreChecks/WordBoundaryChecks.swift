import Foundation
import SwitcherCore

/// Offline event-stream regressions: real Apple layout tables, in-memory text,
/// no CGEvents, input-source selection, Accessibility or user applications.
func wordBoundaryChecks(dictionary: LocalDictionary) -> Int {
    var checks = 0
    var failures = 0
    func expect(_ actual: String?, _ expected: String?, _ name: String) {
        checks += 1
        if actual != expected {
            failures += 1
            print("Boundary regression: \(name): actual=\(actual.debugDescription), expected=\(expected.debugDescription)")
        }
    }
    let english = KeyboardLayoutTable(id: "com.apple.keylayout.ABC")!
    for russianID in InputSources.russianIDs {
        let russian = KeyboardLayoutTable(id: russianID)!
        let convert: (String, Layout) -> String = { text, target in
            target == .russian ? english.convert(text, to: russian) : russian.convert(text, to: english)
        }
        func detect(_ input: String) -> AutoCorrection? {
            AutoCorrection.detect(input, recognizes: dictionary.recognizes,
                                  recognizesFragment: dictionary.recognizesCommon, recognizesBackoff: dictionary.recognizesBackoff, convert: convert)
        }
        func type(_ intended: String, initial: Layout) -> String {
            var active = initial == .english ? english : russian
            var buffer = TypingBuffer()
            var editor = ""
            for character in intended {
                // These tests start in the intended English layout. Afterwards
                // automatic source changes affect subsequent physical keys too.
                guard let physical = english.replacement(String(character)),
                      let typed = active.character(code: physical.code, shift: physical.shift,
                                                   capsLock: physical.capsLock, option: physical.option) else {
                    return "[missing physical key]"
                }
                let alternate = active.id == english.id ? russian : english
                let boundary = WordBoundary.isImmediate(typed, mapped: active.convert(typed, to: alternate),
                    token: buffer.token, mappedToken: active.convert(buffer.token, to: alternate))
                if AutoCorrection.isWordSeparator(typed) || boundary {
                    if let original = buffer.finishWord(), let correction = detect(original + (boundary ? typed : "")) {
                        active = correction.layout == .english ? english : russian
                        guard let keys = KeyboardReplacement.keys(original: original, corrected: correction.text,
                            layout: correction.layout, appendSpace: !boundary,
                            keyProvider: { text, _ in active.replacement(text) }) else { return "[unrepresentable correction]" }
                        for key in keys {
                            if key.code == 51 {
                                guard !editor.isEmpty else { return "[deletion before token]" }
                                editor.removeLast()
                            } else { editor += key.text! }
                        }
                    } else { editor += typed }
                } else { buffer.append(typed); editor += typed }
            }
            return editor
        }
        for phrase in ["can’t ", "don’t ", "isn’t ", "we’ve ", "they’re ", "we’ll ", "he’d ",
                       "I’m ", "John’s ", "can’t! hello ", "he’d hello ", "‘hello’ ", "‘can’t’ "] {
            expect(type(phrase, initial: .english), phrase, russianID + " correct contraction/quote stream " + phrase)
        }
        for expected in ["don’t", "can't", "we’ll", "he’d", "isn’t"] {
            let wrong = english.convert(expected, to: russian)
            for split in 1..<expected.count {
                for input in [String(wrong.prefix(split)) + expected.dropFirst(split),
                              String(expected.prefix(split)) + wrong.dropFirst(split)] where input != expected && input != wrong {
                    expect(detect(input)?.text, expected, russianID + " whole mixed contraction " + input)
                    expect(detect("‘" + input + "’!")?.text, "‘" + expected + "’!", russianID + " wrapped mixed contraction " + input)
                    if let correction = detect(input) {
                        let keys = KeyboardReplacement.keys(original: input, corrected: correction.text,
                            layout: correction.layout, appendSpace: false,
                            keyProvider: { text, _ in english.replacement(text) })
                        expect(keys.map { String($0.prefix(while: { $0.code == 51 }).count) }, String(input.utf16.count),
                               "replacement deletes exactly the complete contraction: " + input)
                        expect(keys.map { $0.dropFirst(input.count).compactMap(\.text).joined() }, expected,
                               "replacement inserts the whole contraction without losing its suffix: " + input)
                    }
                }
            }
        }
        for input in ["can't", "he’d", "John’s", "‘he’d’!", "foo_вщn’t", "вщn’t123", "helloпривет", "xx’жж",
                      "https://example.com/he’d", "user@example.com", "yandex.ru", "(yandex.ru)", "foo_bar", "api/v1"] {
            expect(detect(input)?.text, nil, russianID + " valid spelling / identifier / address kept " + input)
        }
        for token in ["he", "John", "ghbdtn", "b", ""] {
            expect(String(WordBoundary.isImmediate("’", mapped: "’", token: token,
                                                 mappedToken: english.convert(token, to: russian))), "false",
                   "single quote cannot cut the next letters off: " + token)
        }
        for word in ["для", "их", "работает", "такие", "это", "ещё", "хоть", "Яндекс"] {
            let wrong = russian.convert(word, to: english)
            for suffix in ["", "!", "?!", "…"] {
                expect(detect(wrong + suffix)?.text, word + suffix, russianID + " complete physical word " + word + suffix)
                expect(detect(word + suffix)?.text, nil, russianID + " real word kept " + word + suffix)
            }
        }
    }
    guard failures == 0 else { fputs("\(failures)/\(checks) word-boundary regressions failed\n", stderr); exit(1) }
    print("Passed \(checks) word-boundary regressions")
    return checks
}
