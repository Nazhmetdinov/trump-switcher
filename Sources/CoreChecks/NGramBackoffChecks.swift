import Foundation
import SwitcherCore

func ngramBackoffChecks(dictionary: LocalDictionary) -> Int {
    var count = 0
    func expect(_ condition: Bool, _ message: String) {
        guard condition else { fatalError("N-gram backoff: \(message)") }
        count += 1
    }
    // Independent synthetic corpus: all adjacent pairs are supported, but def
    // never occurs. Multiple occurrences in a single spelling are not evidence
    // from multiple words.
    var corpus = Set<String>()
    for fragment in ["ab", "bc", "cd", "de", "ef", "fg", "gh", "hi",
                     "abc", "bcd", "cde", "efg", "fgh", "ghi"] {
        for n in 1...5 { corpus.insert("ab" + fragment + String(repeating: "x", count: n) + "hi") }
    }
    let shape = LexicalShape(words: corpus)
    expect(!shape.permits("abcdefghi"), "strict rule rejects unseen trigram")
    expect(shape.permitsBackoff("abcdefghi"), "one missing trigram uses independently supported pairs")
    for word in ["abcdefg", "abcdefghix", "abcxefghi", "abcdefghi!", "abc1efghi", String(repeating: "a", count: 49)] {
        expect(!shape.permitsBackoff(word), "reject unsupported structure: \(word)")
    }
    expect(!LexicalShape(words: []).permitsBackoff("abcdefghi"), "no training data is not evidence")
    expect(!LexicalShape(words: [String(repeating: "abcdefghi", count: 8)]).permitsBackoff("abcdefghi"),
        "one repeated spelling cannot supply independent support")
    expect(!dictionary.recognizes("abcdefghi", .english), "shape alone never invents dictionary membership")

    let directory = dictionary.resourceDirectory!
    let koi8 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.KOI8_R.rawValue)))
    var newlyRecognized = 0
    for (language, name, encoding) in [(Layout.russian, "ru_modern", koi8), (.english, "en_GB", .utf8)] {
        let frequency = try! String(contentsOf: directory.appendingPathComponent(language == .russian ? "ru_frequency.txt" : "en_frequency.txt"), encoding: .utf8)
        let model = LexicalShape(words: Set(frequency.split(separator: "\n").map(String.init)))
        let entries = try! String(contentsOf: directory.appendingPathComponent(name + ".dic"), encoding: encoding)
        // Deterministic supplementary sample, excluding already recognized words.
        let eligible = Array(Set(entries.split(separator: "\n").dropFirst().map { String($0.split(separator: "/")[0]) }))
            .sorted().filter { $0 == $0.lowercased() && !model.permits($0) && model.permitsBackoff($0) && !dictionary.recognizesCommon($0, language) }
        let sampleCount = min(150, eligible.count)
        let words = (0..<sampleCount).map { eligible[$0 * eligible.count / sampleCount] }
        print("N-gram newly eligible supplementary spellings \(language): \(eligible.count)")
        expect(words.count >= 30, "real supplementary coverage in \(language)")
        print("N-gram supplementary sample \(language): \(words.prefix(12).joined(separator: ", "))")
        let en = KeyboardLayoutTable(id: "com.apple.keylayout.ABC")!
        for id in InputSources.russianIDs {
            let ru = KeyboardLayoutTable(id: id)!
            let convert: (String, Layout) -> String = { text, target in target == .russian ? en.convert(text, to: ru) : ru.convert(text, to: en) }
            var exact = 0
            for word in words {
                expect(dictionary.recognizes(word, language), "backoff still requires real dictionary entry: \(word)")
                newlyRecognized += 1
                func detect(_ text: String, _ settings: CorrectionSettings = CorrectionSettings()) -> String? {
                    AutoCorrection.detect(text, recognizes: dictionary.recognizes, recognizesFragment: dictionary.recognizesCommon, recognizesBackoff: dictionary.recognizesBackoff,
                        settings: settings, convert: convert)?.text
                }
                expect(detect(word) == nil, "valid rare spelling retained: \(word)")
                let wrong = convert(word, language == .russian ? .english : .russian)
                let result = detect(wrong)
                if result == word { exact += 1 }
                expect(result == nil || result == word, "never produce a different rare word: \(word)")
                let mixed = String(word.prefix(1)) + wrong.dropFirst()
                let mixedResult = detect(mixed)
                expect(mixedResult == nil || mixedResult == word, "mixed rare word never truncated: \(word)")
                var excluded = CorrectionSettings(); excluded.excludedWords = [word]
                expect(detect(wrong, excluded) == nil, "target exclusions remain authoritative")
                var disabled = CorrectionSettings(); disabled.toRussian = false; disabled.toEnglish = false
                expect(detect(wrong, disabled) == nil, "direction controls remain authoritative")
                for (before, after) in [("", "."), ("", "!"), ("(", ")"), ("", "...")] {
                    let decorated = detect(before + wrong + after)
                    expect(decorated == nil || decorated == before + word + after, "punctuation cannot truncate rare word: \(before + wrong + after) → \(decorated ?? "skip"), expected \(before + word + after), \(id)")
                    let mixedDecorated = detect(before + mixed + after)
                    expect(mixedDecorated == nil || mixedDecorated == before + word + after, "mixed punctuation cannot truncate rare word: \(word)")
                }
            }
            if id != "com.apple.keylayout.Russian-Phonetic" {
                expect(exact > words.count / 2, "new recognition must improve actual conversion coverage")
            }
            print("N-gram conversions \(language) \(id): \(exact)/\(words.count) exact, remaining preserved")
        }
    }
    expect(newlyRecognized >= 180, "backoff reaches real additional dictionary forms")
    let en = KeyboardLayoutTable(id: "com.apple.keylayout.ABC")!
    let ru = KeyboardLayoutTable(id: "com.apple.keylayout.Russian")!
    expect(AutoCorrection.detect("f,vfqrbyf.", recognizes: dictionary.recognizes,
        recognizesFragment: dictionary.recognizesCommon, recognizesBackoff: dictionary.recognizesBackoff, convert: { text, target in
            target == .russian ? en.convert(text, to: ru) : ru.convert(text, to: en)
        }) == nil, "rare whole word vetoes destructive split before punctuation")
    print("Passed \(count) n-gram backoff checks")
    return count
}
