import Foundation
import SwitcherCore

/// Enumerate the complete authored extension, not a handful of example words.
/// Physical conversion comes from Apple's installed layout tables. No input
/// source is selected and no event is posted to an editor.
func reviewedVocabularyChecks(dictionary: LocalDictionary) -> Int {
    var checks = 0, failures = 0
    func expect(_ value: Bool, _ message: String) {
        if !value {
            failures += 1
            if failures <= 24 { fputs("Reviewed vocabulary: \(message)\n", stderr) }
        }
        checks += 1
    }
    let entries = [Layout.russian, .english].map { layout in
        (layout, ReviewedVocabulary.names(layout).union(ReviewedVocabulary.colloquial(layout)).sorted())
    }
    for (layout, words) in entries {
        for word in words {
            expect((3...48).contains(word.count) && word == word.lowercased(), "bounded lowercase entry: \(word)")
            expect(word.unicodeScalars.allSatisfy { scalar in
                if scalar == "'" { return layout == .english }
                return layout == .russian ? (0x430...0x44f).contains(scalar.value) || scalar.value == 0x451 :
                    (97...122).contains(scalar.value)
            }, "correct alphabet: \(word)")
            expect(dictionary.recognizes(word, layout), "packaged recognition: \(word)")
        }
    }
    for russianID in InputSources.russianIDs {
        let russian = KeyboardLayoutTable(id: russianID)!
        for englishID in InputSources.englishIDs {
            let english = KeyboardLayoutTable(id: englishID)!
            let convert: (String, Layout) -> String = { text, target in
                target == .russian ? english.convert(text, to: russian) : russian.convert(text, to: english)
            }
            func detect(_ text: String, settings: CorrectionSettings = CorrectionSettings()) -> String? {
                AutoCorrection.detect(text, recognizes: dictionary.recognizes,
                    recognizesFragment: dictionary.recognizesCommon, settings: settings, convert: convert)?.text
            }
            for (layout, words) in entries {
                var exact = 0, ambiguous = 0
                for word in words {
                    for spelling in [word, word.prefix(1).uppercased() + word.dropFirst()] {
                        expect(detect(spelling) == nil, "valid spelling unchanged: \(spelling), \(russianID)")
                        let wrong = layout == .russian ? russian.convert(spelling, to: english) : english.convert(spelling, to: russian)
                        let result = detect(wrong)
                        expect(result == nil || result == spelling,
                            "whole word, never fragment: \(wrong) → \(result ?? "skip"), expected \(spelling), \(russianID)")
                        if result == spelling { exact += 1 } else { ambiguous += 1 }
                        for (before, after) in [("", "!"), ("", "?"), ("", "."), ("", ","),
                                                ("", ":"), ("", ";"), ("(", ")"), ("«", "»"), ("\"", "\"")] {
                            let expected = before + spelling + after
                            let decorated = detect(before + wrong + after)
                            expect(decorated == nil || decorated == expected,
                                "punctuation cannot produce another word: \(before + wrong + after) → \(decorated ?? "skip"), expected \(expected), \(russianID)")
                        }
                    }
                    var excluded = CorrectionSettings(); excluded.excludedWords = [word]
                    let wrong = layout == .russian ? russian.convert(word, to: english) : english.convert(word, to: russian)
                    expect(detect(wrong, settings: excluded) == nil, "target exclusion: \(word)")
                }
                expect(exact > words.count, "more than half of bare case variants correct on \(russianID)")
                print("Reviewed corpus \(layout) \(russianID)/\(englishID): \(words.count) entries, \(exact) exact / \(ambiguous) skipped or ambiguous bare spellings")
            }
            for brand in ["iPhone", "ChatGPT", "GitHub", "PlayStation", "JetBrains", "PyCharm", "NumPy", "PyTorch", "ClickHouse", "FastAPI",
                          "McDonald", "O'Connor", "O'Brien"] {
                let wrong = english.convert(brand, to: russian)
                let result = detect(wrong)
                expect(result == brand, "canonical brand capitals: \(brand), \(russianID)")
            }
            for identifier in ["jOhN", "sVeLtE", "iPhOnE", "maXim", "телеГрам"] {
                let wrong = identifier.first?.isASCII == true ? english.convert(identifier, to: russian) : russian.convert(identifier, to: english)
                expect(detect(wrong) == nil, "name list must not license arbitrary internal capitals: \(identifier)")
            }
            for source in ["fooBar", "user_name", "GPT-4o", "https://github.com/test", "person@example.com", "И.О.", "Иванов123", "hello-мир"] {
                expect(detect(source) == nil, "identifier/address/intentional mixed token unchanged: \(source)")
            }
            for (word, target) in [("нейронка", Layout.russian), ("задеплоили", .russian), ("Артём", .russian), ("Алексеевна", .russian),
                                   ("cloudflare", .english), ("Kubernetes", .english), ("Jessica", .english), ("refactoring", .english)] {
                let wrong = target == .russian ? russian.convert(word, to: english) : english.convert(word, to: russian)
                // Phonetic can produce genuine source-language words. Such
                // collisions must stay untouched, never forcibly disambiguated.
                if russianID != "com.apple.keylayout.Russian-Phonetic" {
                    expect(detect(wrong) == word, "required unambiguous name/brand/slang: \(word)")
                }
            }
        }
    }
    guard failures == 0 else { fputs("\(failures)/\(checks) reviewed-vocabulary checks failed\n", stderr); exit(1) }
    print("Passed \(checks) complete reviewed-vocabulary checks")
    return checks
}
