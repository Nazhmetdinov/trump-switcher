import Foundation
import SwitcherCore

/// Fixed regressions for the narrowly adapted RuSwitcher protections. These
/// exercise our complete detector and physical maps, not an upstream executable.
func importedPolicyChecks(dictionary: LocalDictionary) -> Int {
    var count = 0
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fputs("Imported policy: \(message)\n", stderr); exit(1) }
        count += 1
    }
    let english = KeyboardLayoutTable(id: "com.apple.keylayout.ABC")!
    for id in ["com.apple.keylayout.Russian", "com.apple.keylayout.RussianWin"] {
        let russian = KeyboardLayoutTable(id: id)!
        let convert: (String, Layout) -> String = { value, layout in
            layout == .russian ? english.convert(value, to: russian) : russian.convert(value, to: english)
        }
        func detected(_ input: String, _ settings: CorrectionSettings = CorrectionSettings()) -> AutoCorrection? {
            AutoCorrection.detect(input, recognizes: dictionary.recognizes,
                recognizesFragment: dictionary.recognizesCommon, recognizesBackoff: dictionary.recognizesBackoff, settings: settings, convert: convert)
        }
        for (token, word) in [("vs", "мы"), ("dj", "во"), ("kb", "ли"), ("jr", "ок"),
                              ("bp", "из"), ("ye", "ну"), ("ds", "вы")] {
            for (value, expected) in [(token, word), (token.capitalized, word.capitalized), ("(" + token + ")!", "(" + word + ")!")] {
                expect(detected(value)?.text == expected, "restore short Russian word \(word) on \(id)")
            }
            expect(detected(token.uppercased()) == nil, "preserve uppercase English abbreviation on \(id)")
            var caps = CorrectionSettings(); caps.allowAllCaps = true
            expect(detected(token.uppercased(), caps) == nil, "abbreviation protection also applies with all-caps conversion enabled")
        }
        for word in ["эво", "эли"] {
            expect(detected(russian.convert(word, to: english))?.text == word,
                   "short-token guard preserves recognized whole punctuation-key word \(word)")
        }
        expect(detected("dj.") == nil, "existing вою / во. ambiguity stays unchanged")
        for (input, output) in [("lkz", "для"), ("b[", "их"), ("yt", "не"),
                                ("ghbdtn", "привет"), ("руддщ", "hello"), ("bp-pf", "из-за")] {
            expect(detected(input)?.text == output, "existing unambiguous conversion \(input) on \(id)")
            var policy = CorrectionSettings(); policy.excludedWords = [output.uppercased()]
            expect(detected(input, policy) == nil, "target exclusion protects \(output) on \(id)")
            expect(detected("(" + input + ")!", policy) == nil,
                   "wrapped target exclusion protects \(output) on \(id)")
            policy.excludedWords = ["unrelated"]
            expect(detected(input, policy)?.text == output, "unrelated exclusion keeps existing result")
        }
        var policy = CorrectionSettings(); policy.excludedWords = ["привет"]
        expect(detected("приdtn", policy) == nil, "mixed-script target respects exclusion")
        policy.excludedWords = ["yandex.ru"]
        let wrongAddress = english.convert("yandex.ru", to: russian)
        expect(detected(wrongAddress)?.text == "yandex.ru", "address control converts")
        expect(detected(wrongAddress, policy) == nil, "converted address respects exclusion")
        policy.excludedWords = ["hello"]
        policy.rules = [CorrectionRule(input: "myalias", output: "hello", russian: false)]
        expect(detected("myalias", policy) == nil, "target exclusion wins over explicit rule")
        policy.excludedWords = ["vs"]
        policy.rules = [CorrectionRule(input: "vs", output: "тест", russian: true)]
        expect(detected("vs", policy) == nil, "source exclusion still wins over explicit rule")
        policy.excludedWords = []
        expect(detected("vs", policy)?.text == "тест", "explicit rule still overrides short-token guard")
    }
    print("Passed \(count) adapted upstream policy regressions")
    return count
}
