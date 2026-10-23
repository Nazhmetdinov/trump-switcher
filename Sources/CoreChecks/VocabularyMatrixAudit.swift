import Foundation
import SwitcherCore

/// Offline vocabulary audit, deliberately separate from the editor/event tests.
/// Prepared entry point: runVocabularyMatrixAudit(). It reads packaged public
/// dictionaries only; no keyboard events, input-source changes, or user text.
/// --output <report.json>, optional --matrix-fixtures <corpus.jsonl>,
/// optional --matrix-words <sample count per language, default 320>,
/// optional --dictionary-directory <packaged Dictionaries directory>.
func runVocabularyMatrixAudit() throws {
    let arguments = CommandLine.arguments
    func argument(_ name: String) -> String? {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
    let sampleCount = min(5000, max(1, Int(argument("--matrix-words") ?? "320") ?? 320))
    let dictionary = LocalDictionary(directory: argument("--dictionary-directory").map { URL(fileURLWithPath: $0) })
    guard let directory = dictionary.resourceDirectory, dictionary.bundledAvailable else {
        throw NSError(domain: "VocabularyMatrixAudit", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Packaged dictionaries are unavailable"])
    }
    var fixtureHandle: FileHandle?
    if let path = argument("--matrix-fixtures") {
        guard FileManager.default.createFile(atPath: path, contents: nil) else {
            throw NSError(domain: "VocabularyMatrixAudit", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create the requested public corpus file"])
        }
        fixtureHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    }
    defer { try? fixtureHandle?.close() }

    // The packaged frequency sets are alphabetically sorted, without rank or
    // counts. A prefix would overrepresent A/А; use stable length strata instead.
    func stableHash(_ word: String) -> UInt64 {
        word.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
    }
    func sample(_ words: [String], mandatory: [String]) -> [String] {
        let ranked = words.sorted {
            let lhs = stableHash($0), rhs = stableHash($1)
            return lhs == rhs ? $0 < $1 : lhs < rhs
        }
        let quota = max(1, sampleCount / 4)
        var chosen = Set<String>()
        for range in [3...4, 5...8, 9...12, 13...48] {
            chosen.formUnion(ranked.lazy.filter { range.contains($0.count) }.prefix(quota))
        }
        for word in ranked where chosen.count < sampleCount { chosen.insert(word) }
        chosen.formUnion(mandatory)
        return chosen.sorted()
    }
    let requiredRussian = ["а", "я", "и", "в", "к", "с", "у", "о", "не", "на", "их", "им", "для", "это", "что",
        "работает", "привет", "яндекс", "клавиатура", "настройки", "безопасность", "сообщение", "пожалуйста", "спасибо",
        "сегодня", "информация", "приложение", "переключение", "араб", "думаю", "валюта", "июль"]
    let requiredEnglish = ["a", "i", "to", "of", "in", "is", "it", "he", "we", "be", "by", "at", "an", "on", "or",
        "hello", "world", "keyboard", "settings", "security", "message", "please", "thanks", "today", "information",
        "application", "dictionary", "colour", "organise", "yandex"]
    // The automatic short-word policy intentionally does not treat every
    // Hunspell single-letter abbreviation as an ordinary English word.
    let shortEnglish = Set(["a", "i", "to", "of", "in", "is", "it", "he", "we", "be", "by", "at", "an", "as", "am",
        "on", "or", "so", "if", "do", "no", "up", "us", "me", "my", "go", "oh", "ok"])
    func recognizedWord(_ word: String, layout: Layout) -> Bool {
        if word.count <= 2 {
            return layout == .russian ? AutoCorrection.shortRussian.contains(word.lowercased()) : shortEnglish.contains(word.lowercased())
        }
        return dictionary.recognizes(word, layout)
    }
    var selected: [String: [String]] = [:]
    var originalCounts: [String: Int] = [:]
    for (language, mandatory) in [("ru", requiredRussian), ("en", requiredEnglish)] {
        let words = try String(contentsOf: directory.appendingPathComponent(language + "_frequency.txt"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        originalCounts[language] = words.count
        selected[language] = sample(words, mandatory: mandatory)
    }
    let decorations: [(String, String, String)] = [
        ("bare", "", ""), ("period", "", "."), ("comma", "", ","), ("exclamation", "", "!"),
        ("question", "", "?"), ("colon", "", ":"), ("semicolon", "", ";"), ("ellipsis", "", "..."),
        ("question-exclamation", "", "?!"), ("parentheses", "(", ")"), ("quotes", "\"", "\""),
        ("guillemets", "«", "»")
    ]
    var rows: [[String: Any]] = []
    var totals = ["checks": 0, "passed": 0, "failed": 0]
    var exclusions: [String: Int] = [:]
    var exclusionExamples: [String: [String]] = [:]
    var failures: [[String: Any]] = []
    var policyStats: [String: [String: Int]] = [:]
    var decorationStats: [String: [String: Int]] = [:]
    var casingStats: [String: [String: Int]] = [:]
    var fixtureCount = 0
    var ambiguousCases = 0
    var decoratedCollisionCases = 0
    let started = ProcessInfo.processInfo.systemUptime
    func excluded(_ reason: String, _ word: String, wrong: String, language: String, layout: String) {
        exclusions[reason, default: 0] += 1
        let example = "\(language) / \(layout): \(word) → \(wrong)"
        if exclusionExamples[reason, default: []].count < 20 { exclusionExamples[reason, default: []].append(example) }
    }
    func followsScript(_ word: String, layout: Layout) -> Bool {
        !word.isEmpty && word.unicodeScalars.allSatisfy {
            layout == .english ? (65...90).contains($0.value) || (97...122).contains($0.value) :
                (0x410...0x44f).contains($0.value) || $0.value == 0x401 || $0.value == 0x451
        }
    }
    func writeFixture(_ record: [String: Any]) throws {
        guard let fixtureHandle else { return }
        var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes])
        data.append(10)
        try fixtureHandle.write(contentsOf: data)
        fixtureCount += 1
    }
    // Both characters are ordinary visible punctuation, so physical mapping
    // alone cannot determine which punctuation the writer intended. E.g.
    // RussianWin maps a visible '?' to ',' and vice versa. A recognizer must
    // not be scored against one arbitrarily chosen interpretation here.
    let literalPunctuation = Set(".,!?;:()[]{}'\"«»“”‘’…")
    func ambiguousPunctuation(_ input: String, source: KeyboardLayoutTable,
                              target: KeyboardLayoutTable) -> Bool {
        input.contains { character in
            guard literalPunctuation.contains(character) else { return false }
            let mapped = source.convert(String(character), to: target)
            return mapped != String(character) && mapped.count == 1 &&
                mapped.first.map { literalPunctuation.contains($0) } == true
        }
    }

    for englishID in InputSources.englishIDs {
        guard let en = KeyboardLayoutTable(id: englishID) else { continue }
        for russianID in InputSources.russianIDs {
            guard let ru = KeyboardLayoutTable(id: russianID) else { continue }
            let convert: (String, Layout) -> String = { text, target in
                target == .russian ? en.convert(text, to: ru) : ru.convert(text, to: en)
            }
            for (language, target) in [("ru", Layout.russian), ("en", .english)] {
                let source: Layout = target == .russian ? .english : .russian
                let correctTable = target == .russian ? ru : en
                let wrongTable = target == .russian ? en : ru
                var checked = 0, passed = 0, failed = 0, eligibleWords = 0, collisionWords = 0
                var rowAmbiguities = 0, rowDecoratedCollisions = 0
                func check(_ input: String, expected: String?, policy: String, word: String,
                           casing: String, decoration: String, allCaps: Bool = false) throws {
                    var settings = CorrectionSettings(); settings.allowAllCaps = allCaps
                    let actual = AutoCorrection.detect(input, recognizes: dictionary.recognizes,
                        recognizesFragment: dictionary.recognizesCommon, recognizesBackoff: dictionary.recognizesBackoff, settings: settings, convert: convert)?.text
                    let success = actual == expected
                    checked += 1; totals["checks", default: 0] += 1
                    if success { passed += 1; totals["passed", default: 0] += 1 }
                    else { failed += 1; totals["failed", default: 0] += 1 }
                    let result = success ? "passed" : "failed"
                    policyStats[policy, default: [:]][result, default: 0] += 1
                    decorationStats[decoration, default: [:]][result, default: 0] += 1
                    casingStats[casing, default: [:]][result, default: 0] += 1
                    var fixture: [String: Any] = ["input": input, "expectedText": expected ?? input,
                        "expectCorrection": expected != nil, "policy": policy, "word": word, "language": language,
                        "sourceLayoutID": policy == "preserve-correct-text" ? correctTable.id : wrongTable.id,
                        "targetLayoutID": expected != nil || policy == "preserve-correct-text" ? correctTable.id : wrongTable.id,
                        "casing": casing, "decoration": decoration, "allowAllCaps": allCaps,
                        "scope": "recognizer-only; not editor input", "recordType": "check", "result": result]
                    if !success {
                        fixture["actualText"] = actual ?? input
                        fixture["actualCorrection"] = actual != nil
                        failures.append(fixture)
                    }
                    try writeFixture(fixture)
                }
                for word in selected[language] ?? [] {
                    let wrongStem = correctTable.convert(word, to: wrongTable)
                    // The source-word oracle is independent of detect(). Never
                    // select only samples that the algorithm already converts.
                    let collision = recognizedWord(wrongStem, layout: source)
                    if collision {
                        collisionWords += 1
                        excluded("known-source-word", word, wrong: wrongStem, language: language, layout: russianID)
                        try check(wrongStem, expected: nil, policy: "preserve-lexical-collision", word: word,
                                  casing: "lower", decoration: "bare")
                        continue
                    }
                    guard followsScript(wrongStem, layout: source), wrongStem != word,
                          wrongTable.convert(wrongStem, to: correctTable) == word else {
                        // б/ю/ж etc. can be punctuation in the wrong layout.
                        // Those intrinsically ambiguous cases stay in the full
                        // 80,000-word audit; do not call them successful here.
                        excluded("encoded-punctuation-or-nonroundtrip", word, wrong: wrongStem,
                                 language: language, layout: russianID)
                        continue
                    }
                    guard recognizedWord(word, layout: target) else {
                        excluded("not-recognized-target", word, wrong: wrongStem, language: language, layout: russianID)
                        continue
                    }
                    eligibleWords += 1
                    for casing in ["lower", "title", "upper-opt-in"] {
                        if word.count == 1 && casing != "lower" {
                            excluded("capital-initial-policy", word, wrong: wrongStem, language: language, layout: russianID)
                            continue
                        }
                        let capitalized = String(word.prefix(1)).uppercased() + String(word.dropFirst())
                        let spelled = casing == "lower" ? word : casing == "title" ? capitalized : word.uppercased()
                        for (name, prefix, suffix) in decorations {
                            let expected = prefix + spelled + suffix
                            let input = correctTable.convert(expected, to: wrongTable)
                            // Classify before invoking detect: adding punctuation
                            // can create a real source word (at. -> фею). Preserve
                            // that real word instead of demanding its destruction.
                            if followsScript(input, layout: source), recognizedWord(input, layout: source) {
                                decoratedCollisionCases += 1; rowDecoratedCollisions += 1
                                excluded("decorated-source-word", word, wrong: input,
                                         language: language, layout: russianID)
                                try check(input, expected: nil, policy: "preserve-decorated-source-word", word: word,
                                          casing: casing, decoration: name, allCaps: casing == "upper-opt-in")
                            } else if ambiguousPunctuation(input, source: wrongTable, target: correctTable) {
                                ambiguousCases += 1; rowAmbiguities += 1
                                excluded("literal-punctuation-ambiguity", word, wrong: input,
                                         language: language, layout: russianID)
                                decorationStats[name, default: [:]]["excluded", default: 0] += 1
                                casingStats[casing, default: [:]]["excluded", default: 0] += 1
                                try writeFixture(["recordType": "excluded", "result": "excluded",
                                    "reason": "literal-punctuation-ambiguity", "input": input,
                                    "physicalInterpretation": expected, "word": word, "language": language,
                                    "sourceLayoutID": wrongTable.id, "targetLayoutID": correctTable.id,
                                    "casing": casing, "decoration": name, "allowAllCaps": casing == "upper-opt-in",
                                    "scope": "Ambiguous oracle: not executed, not a pass, not editor input"])
                            } else {
                                try check(input, expected: expected, policy: "convert-unambiguous-stem", word: word,
                                          casing: casing, decoration: name, allCaps: casing == "upper-opt-in")
                            }
                            try check(expected, expected: nil, policy: "preserve-correct-text", word: word,
                                      casing: casing, decoration: name, allCaps: casing == "upper-opt-in")
                        }
                    }
                    if word.count > 1 {
                        try check(correctTable.convert(word.uppercased(), to: wrongTable), expected: nil,
                                  policy: "default-preserve-capitals", word: word, casing: "upper-default", decoration: "bare")
                    }
                }
                rows.append(["englishLayout": englishID, "russianLayout": russianID, "language": language,
                    "selectedWords": selected[language]?.count ?? 0, "eligibleUnambiguousWords": eligibleWords,
                    "sourceCollisionWords": collisionWords, "decoratedSourceWordControls": rowDecoratedCollisions,
                    "excludedAmbiguousPunctuationCases": rowAmbiguities,
                    "checks": checked, "passed": passed, "failed": failed])
            }
        }
    }
    let report: [String: Any] = [
        "scope": "Offline dictionary and recognition matrix only. No keyboard events, AX, editor, or user application was exercised.",
        "sampling": "Stable FNV-1a sampling within word-length strata; public frequency packs are alphabetically sorted, not ranked.",
        "selectionRule": "Word selection and case classification happen independently of AutoCorrection.detect. Bare and decorated source-word collisions are explicit preserve controls.",
        "excludedScope": "Visible punctuation with two punctuation interpretations is explicitly excluded, not executed and not a pass. Encoded punctuation letters and nonroundtripping spellings remain covered by the separate full bare-word audit.",
        "dictionaryDirectory": directory.path,
        "sourceWordCounts": originalCounts, "selectedWords": selected, "requestedSamplePerLanguage": sampleCount,
        "rows": rows, "totals": totals, "exclusions": exclusions, "exclusionExamples": exclusionExamples,
        "decoratedSourceWordControls": decoratedCollisionCases, "excludedAmbiguousPunctuationCases": ambiguousCases,
        "policyStats": policyStats, "decorationStats": decorationStats, "casingStats": casingStats,
        "failures": failures, "failuresFirst200": Array(failures.prefix(200)), "corpusFixturesWritten": fixtureCount,
        "seconds": ProcessInfo.processInfo.systemUptime - started
    ]
    if let path = argument("--output") {
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: URL(fileURLWithPath: path), options: .atomic)
    }
    print("Vocabulary matrix: \(totals["checks", default: 0]) checks, \(totals["passed", default: 0]) passed, \(totals["failed", default: 0]) failed; recognizer only, no editor input")
}
